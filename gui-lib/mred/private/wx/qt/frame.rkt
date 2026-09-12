#lang racket/base
; Qt frame% — wraps a QMainWindow via the shim.
(require racket/class
         "../common/queue.rkt"
         "window.rkt"
         "utils.rkt")

(provide frame%
         display-size
         display-origin
         display-count
         display-bitmap-resolution)

(define frame%
  (class window%
    (init parent           ; platform parent frame or #f
          label            ; window title string
          x y              ; initial position (-1/#f = auto)
          w h              ; initial size (-1/#f = default)
          style)           ; style symbol list

    ; close-cb captures `this` — valid because the lambda runs later.
    (define close-cb
      (lambda (ud)
        (qt-queue-window-event this
          (lambda ()
            (unless (other-modal? this)
              (when (send this on-close)
                (send this direct-show #f)))))))

    (define qt-handle (shim_window_create close-cb #f))
    ; The central QWidget* that canvas/button/panel children parent to.
    (define content-handle (shim_window_get_content_widget qt-handle))

    (super-new [handle     qt-handle]
               [parent     parent]
               [eventspace (current-eventspace)])

    (shim_window_set_title qt-handle (or label ""))
    (let ([nw (if (and w  (> w  0)) w  400)]
          [nh (if (and h  (> h  0)) h  300)])
      (shim_window_set_size qt-handle nw nh)
      (set-size (or x -1) (or y -1) nw nh))

    ; ---- platform interface (called by wxtop.rkt glue) ----

    (define/public (direct-show on?)
      (register-frame-shown this on?)
      (super show on?)
      (shim_window_show qt-handle (if on? 1 0)))

    (define/override (show on?)
      (direct-show on?))

    ; Terminates the recursive is-shown-to-root?/is-enabled-to-root? walk
    ; (window.rkt, docs/HACKING.md §26) -- a frame's `parent` is an owner
    ; frame or #f, not a containment parent, so the chain must not recurse
    ; into it. is-shown-to-root? bottoms out at this frame's own (plain,
    ; non-recursive) is-shown?, mirroring wx/win32/frame.rkt:406-407.
    ; is-enabled-to-root? does NOT mirror win32's unconditional #t
    ; (win32/frame.rkt:408-409) -- win32 can hardcode #t there because its
    ; own `enable` calls EnableWindow, so the OS itself stops input to a
    ; disabled frame; win32's Racket-side gate is genuinely redundant. Qt's
    ; `enable` (window.rkt) only flips the Racket-side `enabled?` field --
    ; nothing calls shim_widget_set_enabled from there (only modal-enable
    ; does, directly, bypassing this method entirely) -- so hardcoding #t
    ; here would silently disable dispatch-on-char/dispatch-on-event's gate
    ; (window.rkt:211,220) for a disabled frame. Falls back to this frame's
    ; own enabled? flag instead, via the plain accessor (window.rkt:77).
    (define/override (is-shown-to-root?)   (send this is-shown?))
    (define/override (is-enabled-to-root?) (send this is-window-enabled?))
    (define/override (is-frame?) #t)

    (define/override (set-size nx ny nw nh)
      (super set-size nx ny nw nh)
      (when (and nw (> nw 0) nh (> nh 0))
        (shim_window_set_size qt-handle nw nh)))

    ; ---- window state (maximize/iconize/fullscreen, docs/HACKING.md §27) ----
    ; window%'s base stubs (iconized?/maximize/is-maximized?/fullscreen/
    ; fullscreened? -- all hardcoded #f/no-op) were never overridden here
    ; before; frame% now delegates to the shim, which toggles individual
    ; Qt::WindowStates bits via setWindowState() (see shim.cpp) rather than
    ; calling showMaximized()/showMinimized()/showFullScreen()/showNormal()
    ; -- those convenience methods also force setVisible(true), which would
    ; wrongly show a not-yet-shown frame the moment `maximize` is called
    ; (exactly mrtop.rkt's position-for-initial-show + maximize-before-show
    ; flow), and showNormal() would clear all three state bits together
    ; instead of restoring just the one being toggled. Mirrors win32's
    ; observable behavior (win32/frame.rkt:584-673) without duplicating its
    ; independent GWL_STYLE-based bookkeeping.
    ; `iconize` (the setter -- there is no base window.rkt stub for it,
    ; matching win32/frame.rkt:599 having its own define/public with no
    ; base-class counterpart either) is called directly by mred/private/
    ; mrtop.rkt's frame% glue.
    (define/override (maximize on?)
      (shim_window_maximize qt-handle (if on? 1 0)))
    (define/override (is-maximized?)
      (= 1 (shim_window_is_maximized qt-handle)))
    (define/public (iconize on?)
      (shim_window_iconize qt-handle (if on? 1 0)))
    (define/override (iconized?)
      (= 1 (shim_window_is_iconized qt-handle)))
    (define/override (fullscreen on?)
      (shim_window_fullscreen qt-handle (if on? 1 0)))
    (define/override (fullscreened?)
      (= 1 (shim_window_is_fullscreen qt-handle)))

    (define/public (set-label lbl)
      (shim_window_set_title qt-handle lbl))

    (define/public (set-title s)
      (shim_window_set_title qt-handle s))

    (define/public set-icon
      (case-lambda
        [(i) (void)]
        [(i b) (void)]
        [(i b l?) (void)]))

    ; Default: allow close; wxtop.rkt overrides to ask mred wrapper
    (define/override (on-close)           #t)
    ; on-activate, display-changed: override* targets in make-top-level-window-glue%
    (define/override (on-activate on?)    (void))
    (define/override (display-changed)    (void))

    ; make-top-container% inherits enforce-size (also defined in window% for dialog stubs)
    (define/override (enforce-size min-x min-y max-x max-y inc-x inc-y) (void))

    ; get-focus-window: inherited from window% (tracks focus via on-set-focus/on-kill-focus)
    ; add-border-button, forget-child: NOT here — added by wxtop.rkt via public*

    (define/override (get-qt-handle)    qt-handle)
    (define/override (get-content-hwnd) content-handle)
    ; show-control, add-child, forget-child: NOT here — added by
    ; make-top-container% (wxtop.rkt) via public*

    ; Stub methods — window% provides base, frame% overrides where needed
    ; get-the-menu-bar, get-mdi-parent, set-mdi-parent, handle-menu-key:
    ; NOT here — added by wx-frame% (wxtop.rkt:715) via public*
    ; position-for-initial-show: NOT here — added by make-top-container% via public*
    (define/override (set-resize-corner on?) (void))
    (define/public (get-scaled-client-size)
      (let ([wb (box 0)] [hb (box 0)])
        (send this get-client-size wb hb)
        (values (unbox wb) (unbox hb))))
    ; Attaches a QMenuBar to this QMainWindow.
    ; mb is wx-menu-bar% (glue extends platform menu-bar%).
    (define/override (set-menu-bar mb)
      (when mb
        (shim_window_set_menubar qt-handle (send mb get-menubar-handle))
        (send mb set-frame this)))

    ; on-menu-command, on-menu-click, on-toolbar-click, on-mdi-activate:
    ; override* targets from wx-frame% — frame% overrides window%'s stubs
    (define/override (on-menu-command id)   (void))
    (define/override (on-menu-click)        (void))
    (define/override (on-toolbar-click)     (void))
    (define/override (on-mdi-activate on?)  (void))
    (define/override (get-top-frame) this)
    (define/override (get-dialog-level) 0)

    ; ---- modal parent-disable (docs/HACKING.md §18.3) ----
    ; Called by dialog%'s direct-show on every top-level window in the
    ; eventspace, mirroring wx/win32/frame.rkt's modal-enable: disables this
    ; frame's own QMainWindow (which Qt cascades to all its child controls)
    ; while some other frame has an open modal dialog, re-enables once none
    ; does. `ignoring` is the dialog being closed (so it doesn't count
    ; itself as "other" during its own direct-show #f).
    (define modal-enabled? #t)
    (define/public (modal-enable ignoring)
      (define on? (not (other-modal? this #f ignoring)))
      (unless (eq? modal-enabled? on?)
        (set! modal-enabled? on?)
        (shim_widget_set_enabled qt-handle (if on? 1 0))))

    ; Called by mrtop.rkt on the first frame; cocoa uses it to set the app delegate,
    ; gtk/win32 are no-ops.  Qt needs no special treatment here.
    (define/public (designate-root-frame) (void))

    ; Sizing helpers used by make-top-container%
    (define/public (min-width)  0)
    (define/public (min-height) 0)
    (define/override (queue-on-size) (void))))

; ---- display info stubs -------------------------------------------------

(define (display-size xb yb [all? #f] [num 0] [fail-thunk #f])
  (set-box! xb 1920)
  (set-box! yb 1080))

(define (display-origin xb yb [all? #f] [num 0] [fail-thunk #f])
  (set-box! xb 0)
  (set-box! yb 0))

(define (display-count) 1)

(define (display-bitmap-resolution [num 0] [fail-thunk #f]) 1)

