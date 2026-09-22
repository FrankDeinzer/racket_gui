#lang racket/base
; Qt platform module — exports platform-values for Racket's GUI toolkit.
; Spike implementation: frame%, canvas%, button%, check-box%, list-box% are
; real; rest are stubs.
(require racket/class
         racket/draw
         "../../lock.rkt"
         "../common/default-procs.rkt"
         "../common/cursor-draw.rkt"
         "frame.rkt"
         "canvas.rkt"
         "button.rkt"
         "check-box.rkt"
         "list-box.rkt"
         "choice.rkt"
         "radio-box.rkt"
         "slider.rkt"
         "gauge.rkt"
         "tab-panel.rkt"
         "group-panel.rkt"
         "dialog.rkt"
         "panel.rkt"
         "window.rkt"
         "menu-bar.rkt"
         "menu.rkt"
         "menu-item.rkt"
         "message.rkt"
         "filedialog.rkt"
         "printer-dc.rkt"
         "queue.rkt"
         "utils.rkt")

(provide (protect-out platform-values))

; ---- stub class factory ---------------------------------------------------
; Stub classes extend window% so the glue layers (wx-make-window%, make-item%)
; can inherit is-shown-to-root?, is-enabled-to-root?, etc.
(define (make-stub-class name)
  (class window%
    (init-rest args)
    (define the-parent (if (pair? args) (car args) #f))
    (super-new [handle #f] [parent the-parent])
    ; Widget interface stubs so glue layers can `inherit` them:
    (define/public (command e)       (void))
    (define/public (set-border on?)  (void))
    (define/public (set-value v)     (void))
    (define/public (get-value)       #f)
    ; variadic: button-style callers pass (label); other stub consumers may
    ; pass (index label) -- mirrors `append`'s rest-arg treatment above.
    (define/public (set-label . args) (void))
    (define/public (get-label)        "")
    (define/public (set-selection i) (void))
    (define/public (get-selection)   -1)
    (define/public (clear)           (void))
    (define/public (append . args)   (void))
    (define/public (defaulting on?)  (void))
    (define/public (has-border?)     #f)
    (define/public (on-choice-reorder new-positions) (void))
    (define/public (on-choice-close pos)             (void))
    ; list-box specific methods inherited by wx-internal-list-box%
    (define/public (get-first-item)         0)
    (define/public (set-first-visible-item i) (void))
    (define/public (number-of-visible-items) 0)
    ; radio-box/choice/list-box: item count
    (define/public (number)                  0)
    ; gauge
    (define/public (set-gauge-value v)       (void))
    (define/public (get-gauge-value)         0)
    ; slider
    (define/public (set-slider-value v)      (void))
    (define/public (get-slider-value)        0)
    ; button-focus for radio-box/tab-panel
    (define/public (button-focus i)          -1)
    ; char-to: NOT here — added by wx-make-window% (wxwindow.rkt) via public*
    ; label setting for controls (button-style set-label)
    (define/public (set-item n label)        (void))
    (define/public (get-item-label n)        "")
    ; canvas group-panel
    (define/public (adopt-child c)           (void))
    (define/public (get-label-position)      'horizontal)
    (define/public (set-label-position pos)  (void))
    (define/public (set-item-cursor x y)     (void))
    ; menu-related methods (needed by wx-menu-bar% and wx-menu% glue)
    (define/public (delete label pos)                (void))
    (define/public (delete-by-position pos)          (void))
    ; append is already defined above (as (append s)) — redefine as case-lambda
    ; to support both (append s) and (append menu title) arities
    (define/public (enable-top pos on?)              (void))
    ; on-combo-select: expected by wxtextfield.rkt via override* on combo controls
    (define/public (on-combo-select i)               (void))
    ; set-callback: mrpanel.rkt sends this to the tab widget (get-tab-widget)
    (define/public (set-callback cb)                 (void))))

; ---- unimplemented stubs ---------------------------------------------------

; canvas-panel% is the real implementation (canvas.rkt); imported above
; check-box% is the real implementation (check-box.rkt); imported above
; choice% is the real implementation (choice.rkt); imported above
; dialog% is the real implementation (dialog.rkt); imported above
; gauge% is the real implementation (gauge.rkt); imported above
; group-panel% is the real implementation (group-panel.rkt); imported above
; list-box% is the real implementation (list-box.rkt); imported above
; menu%, menu-bar%, menu-item% are real implementations (menu*.rkt); imported above
; message% is the real implementation (message.rkt); imported above
; printer-dc% is the real implementation (printer-dc.rkt); imported above
; radio-box% is the real implementation (radio-box.rkt); imported above
; slider% is the real implementation (slider.rkt); imported above
; tab-panel% is the real implementation (tab-panel.rkt); imported above

; ---- minimal item% and clipboard/cursor stubs ------------------------------

(define item%
  (class window%
    (init-rest args)
    (super-new [handle #f] [parent #f])
    (define/public   (command e) (void))
    (define/override (gets-focus?) #t)))

; Text only (docs/2026-09-14-4_report-linux.md "Nachtrag": copy/paste was a
; pure no-op stub). Method names/arities follow the contract wx/common/
; clipboard.rkt's clipboard% actually calls (verified against gtk's/cocoa's
; clipboard-driver% -- NOT the previous stub's ad-hoc get-data/set-data/
; same-client? names, which nothing in shared code ever called).
;
; QClipboard is a plain synchronous global, so unlike gtk's async ownership-
; callback dance we write through eagerly on set-client and read back live
; on every get-text-data/get-data("TEXT") -- always correct even when some
; other application changed the system clipboard behind our back. Only the
; non-text "WXME" rich-paste format (wxme/editor.rkt) needs the client-owns-
; clipboard check below, so a real self-copy/paste round-trips formatting
; while an external-app copy falls back to plain text.
(define clipboard-driver%
  (class object%
    (init [x-selection? #f])
    (super-new)

    (define client #f)
    (define client-types #f)
    (define last-set-text #f)

    (define (native-text)
      (and (shim_clipboard_has_text) (shim_clipboard_get_text)))

    (define (client-owns-clipboard?)
      (and client (equal? (native-text) last-set-text)))

    (define/public (get-client)
      (and (client-owns-clipboard?) client))

    (define/public (set-client c orig-types)
      (define d (send c get-data "TEXT"))
      (define txt (cond [(bytes? d) (bytes->string/utf-8 d #\?)]
                         [(string? d) d]
                         [else #f]))
      (set! client c)
      (set! client-types orig-types)
      (set! last-set-text txt)
      (when txt (shim_clipboard_set_text txt)))

    (define/public (get-data fmt)
      (cond
        [(equal? fmt "TEXT") (native-text)]
        [(and (client-owns-clipboard?) (member fmt client-types))
         (send client get-data fmt)]
        [else #f]))

    (define/public (get-text-data) (or (native-text) ""))

    ; Bitmap clipboard is out of scope for this spike (never worked before
    ; either -- the old stub had no methods for it at all).
    (define/public (get-bitmap-data)         #f)
    (define/public (set-bitmap-data bm time) (void))))

; QCursor supports true ARGB images directly, so unlike win32's AND/XOR-mask
; HCURSOR dance, a custom cursor here is just "turn a bitmap%+mask into an
; ARGB buffer, hand it to the shim" -- image->argb-handle below is that one
; conversion, shared by set-image and by 'bullseye (the one standard symbol
; with no native Qt::CursorShape, drawn the same way win32/gtk draw it).
(define (image->argb-handle image mask hot-spot-x hot-spot-y)
  (define w (send image get-width))
  (define h (send image get-height))
  (define argb (make-bytes (* w h 4) 0))
  (send image get-argb-pixels 0 0 w h argb)
  (if mask
      (send mask get-argb-pixels 0 0 w h argb #t)
      (send image get-argb-pixels 0 0 w h argb #t))
  (shim_cursor_create_from_argb argb w h hot-spot-x hot-spot-y))

(define cursor-driver%
  (class object%
    (super-new)
    (define handle #f)

    (define/public (ok?) (and handle #t))

    (define/public (set-standard sym)
      (set! handle
            (case sym
              [(bullseye)
               (image->argb-handle (make-cursor-image draw-bullseye 'unsmoothed) #f 8 8)]
              [(arrow cross hand ibeam watch blank
                size-n/s size-e/w size-ne/sw size-nw/se arrow+watch)
               (shim_cursor_create_standard (symbol->string sym))]
              [else #f])))

    (define/public (set-image image mask hot-spot-x hot-spot-y)
      (set! handle (image->argb-handle image mask hot-spot-x hot-spot-y)))

    (define/public (get-handle) handle)))

; ---- function stubs -------------------------------------------------------

; can-show-print-setup?/show-print-setup: real implementations
; (printer-dc.rkt); imported above.
; id is `this` from platform menu-item%'s (id) method, i.e. the wx-level
; glue instance itself (mirrors gtk's `(define (id-to-menu-item i) i)`,
; wx/gtk/procs.rkt). wxtop.rkt's on-menu-command applies the generic
; `wx->mred` conversion itself after this call returns -- calling
; `get-mred` here too was a double conversion and crashed (`generic:get-mred:
; target is not an instance of the generic's interface`) because `this`,
; while dynamically the most-derived object, is not guaranteed to satisfy
; wx<%> at the point `(id)` runs. docs/HACKING.md §19.
(define (id-to-menu-item id) id)
; file-selector: real implementation (filedialog.rkt); imported above
(define (is-color-display?)              #t)
(define (get-display-depth)              32)
(define (has-x-selection?)               #f)
(define (hide-cursor)                    (void))
; QApplication::beep() -- gtk calls gdk_display_beep(), win32 calls
; MessageBeep(MB_OK); was a no-op here before.
(define (bell)                           (shim_bell))
; QCursor::pos() + QGuiApplication::mouseButtons()/queryKeyboardModifiers() are
; already portable across all three platforms (unlike win32's own procs.rkt,
; which has no cross-platform notion of 'middle/'meta and skips them) -- only
; caps-lock has no Qt-level query and stays Windows-specific in the shim
; (shim_get_mouse_state's #ifdef _WIN32), matching win32's own GetAsyncKeyState
; check exactly since this backend also runs on Windows.
(define (get-current-mouse-state)
  (define-values (x y flags) (shim_get_mouse_state))
  (define (maybe bit sym) (if (zero? (bitwise-and flags bit)) '() (list sym)))
  (values (make-object point% x y)
          (append (maybe #x01 'left)
                  (maybe #x02 'middle)
                  (maybe #x04 'right)
                  (maybe #x08 'shift)
                  (maybe #x10 'control)
                  (maybe #x20 'alt)
                  (maybe #x40 'meta)
                  (maybe #x80 'caps))))
(define (cancel-quit)                    (void))
; QApplication::font(), resolved against the real font database (docs/HACKING.md,
; Block C 2026-09-22) -- was a hardcoded "Arial"/11/#f before, which doesn't
; exist as an installed family on most Linux systems and isn't the macOS
; system UI font either.
; Queried live (like gtk's GtkSettings read, not win32's cached theme font)
; on each call, matching gtk/win32's own per-call contract -- though
; gdi.rkt:89 snapshots the result into normal-control-font once at module
; load, so nothing downstream currently re-reads it during a running
; process; this only matters for other/future direct callers.
(define (get-control-font-face)          (shim_control_font_face))
(define (control-font-size+in-pixels?)   (call-with-values shim_control_font_size cons))
(define (get-control-font-size)          (car (control-font-size+in-pixels?)))
(define (get-control-font-size-in-pixels?) (cdr (control-font-size+in-pixels?)))
; QApplication::doubleClickInterval() -- gtk reads the live gtk-double-click-time
; GSetting; win32 also hardcodes 500 here (Phase 1 audit), so this Qt query
; upgrades Linux beyond gtk-parity's own baseline, not just win32's.
(define (get-double-click-time)          (shim_double_click_time))
(define (location->window x y)          #f)
(define (shortcut-visible-in-label? [? #f]) #t)
(define (unregister-collecting-blit canvas) (void))
(define (register-collecting-blit canvas x y w h on off ox oy fx fy) (void))
; gtk's flush-display is `pre-event-sync` (its own, Qt-foreign event-pump
; primitive, common/queue.rkt) followed by gdk_display_flush (a pure X11
; protocol flush, no event dispatch). Qt has no exposed "push queued draws,
; dispatch nothing" primitive in this shim, so the architecturally sanctioned
; equivalent is `shim_pump(0)` -- NOT QApplication::processEvents() called
; directly (that would be the nested loop Regel 1 forbids), but the exact
; same (atomically (shim_pump 0)) call already used in queue.rkt's
; set-queue-wakeup!/qt-start-event-pump and filedialog.rkt (docs/HACKING.md
; §39). This is safe from re-entrant nesting because C-to-Racket callbacks
; here only ever post events and return (Regel 2) -- no Racket-level
; consumer code (like flush-display's own caller) ever runs synchronously
; inside a shim_pump call's C stack, and Racket's green threads are
; cooperatively scheduled on one OS thread, serialized further by
; `atomically`, so two shim_pump calls can never be concurrently in flight.
; Caveat: unlike gdk_display_flush, this also dispatches pending input
; events, not just a protocol flush -- narrow known consumer (framework/
; splash.rkt's splash-screen animation) makes that an acceptable difference.
(define (flush-display)                  (atomically (shim_pump 0)))
; mred/private/mred.rkt's find-graphical-system-path wraps this with
; `(or (wx:find-graphical-system-path what) (case what [(init-file) ...
; ~/.gracketrc or gracketrc.rktl] [else #f]))` -- a real fallback that
; computes the correct .gracketrc-family path. The previous `(init-file)`
; case here returned `(find-system-path 'init-file)` (Racket's OWN init
; file, e.g. ~/.racketrc) instead of #f, which is truthy and therefore
; short-circuited that `or`, silently loading the wrong startup file under
; this backend. Returning #f for 'init-file lets mred.rkt's fallback run,
; matching both gtk (only handles 'x-display) and win32 (blanket #f).
(define (find-graphical-system-path what)
  (case what
    [(x-display)
     (and (eq? (system-type) 'unix)
          (getenv "DISPLAY")
          (string->path (getenv "DISPLAY")))]
    [else #f]))
(define (play-sound file async?) #f)
(define (font-from-user-platform-mode)  #f)
(define (get-font-from-user msg parent  init) #f)
(define (color-from-user-platform-mode) 'dialog)
(define (get-color-from-user msg parent init) #f)
(define (get-highlight-background-color)
  (make-object color% 0 120 215))
(define (get-highlight-text-color)
  (make-object color% 255 255 255))
(define (get-label-foreground-color)
  (make-object color% 0 0 0))
(define (get-label-background-color)
  (make-object color% 240 240 240))
(define (make-screen-bitmap w h)
  (make-object bitmap% w h #f #t))
(define (make-gl-bitmap w h ctx)  #f)
(define (check-for-break)        #f)
(define (key-symbol-to-menu-key sym) #f)
(define (needs-grow-box-spacer?) #f)
(define (graphical-system-type)  'qt)
(define (tab-panel-available?)   #t)
(define (white-on-black-panel-scheme?)
  (let ([bg (get-label-background-color)]
        [fg (get-label-foreground-color)])
    (< (+ (* .2126 (/ (send bg red) 255))
          (* .7152 (/ (send bg green) 255))
          (* .0722 (/ (send bg blue) 255)))
       (+ (* .2126 (/ (send fg red) 255))
          (* .7152 (/ (send fg green) 255))
          (* .0722 (/ (send fg blue) 255))))))

; ---- init Qt ---------------------------------------------------------------

; Called once when this module is first required (i.e. when platform-values
; is called for the first time by wx/platform.rkt). Both calls return
; non-void values (a plumber-flush-handle, a thread) -- void them out so the
; module-instantiation printer (active for the "main" module in this
; require chain) doesn't echo them to stdout on every Qt-backend startup.
(void (qt-init!))
(void (qt-start-event-pump))

; ---- platform-values -------------------------------------------------------

(define (platform-values)
  (values
   button%
   canvas%
   canvas-panel%
   check-box%
   choice%
   clipboard-driver%
   cursor-driver%
   dialog%
   frame%
   gauge%
   group-panel%
   item%
   list-box%
   menu%
   menu-bar%
   menu-item%
   message%
   panel%
   printer-dc%
   radio-box%
   slider%
   tab-panel%
   window%
   can-show-print-setup?
   show-print-setup
   id-to-menu-item
   file-selector
   is-color-display?
   get-display-depth
   has-x-selection?
   hide-cursor
   bell
   display-size
   display-origin
   display-count
   display-bitmap-resolution
   flush-display
   get-current-mouse-state
   fill-private-color
   cancel-quit
   get-control-font-face
   get-control-font-size
   get-control-font-size-in-pixels?
   get-double-click-time
   file-creator-and-type
   location->window
   shortcut-visible-in-label?
   unregister-collecting-blit
   register-collecting-blit
   find-graphical-system-path
   play-sound
   get-panel-background
   font-from-user-platform-mode
   get-font-from-user
   color-from-user-platform-mode
   get-color-from-user
   special-option-key
   special-control-key
   any-control+alt-is-altgr
   get-highlight-background-color
   get-highlight-text-color
   get-label-foreground-color
   get-label-background-color
   make-screen-bitmap
   make-gl-bitmap
   check-for-break
   key-symbol-to-menu-key
   needs-grow-box-spacer?
   graphical-system-type
   white-on-black-panel-scheme?
   tab-panel-available?))
