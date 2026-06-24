#lang racket/base
; Minimal base window class shared by frame%, canvas%, button%, panel%.
;
; IMPORTANT: Do NOT add methods that the glue layers (wxwindow.rkt,
; wxitem.rkt) add via `public*`. Those include:
;   get-container, set-container, get-window, get-top-level,
;   dx, dy, ext-dx, ext-dy, area-parent, is-enabled?,
;   skip-subwindow-events?, get-text-extent, has-focus?,
;   accept-drag?, tabbing-position, has-tabbing-children?,
;   on-visible, queue-visible, on-active, queue-active, etc.
;
; Only define what the platform class itself owns:
;   - handle storage + get-handle
;   - eventspace, parent
;   - core visibility/enable state
;   - geometry
;   - platform-level stubs for callbacks (on-set-focus etc.)
(require racket/class
         "../common/queue.rkt")

(provide window%
         qt-queue-window-event
         qt-queue-window-refresh-event)

(define (qt-queue-window-event win thunk)
  (queue-event (send win get-eventspace) thunk))

(define (qt-queue-window-refresh-event win thunk)
  (queue-refresh-event (send win get-eventspace) thunk))

(define window%
  (class object%
    (init-field [handle     #f]
                [parent     #f]
                [eventspace (current-eventspace)])

    (define w 0)
    (define h 0)
    (define x-pos 0)
    (define y-pos 0)
    (define enabled? #t)
    (define shown?   #f)

    ; ---- handle ---
    (define/public (get-handle)       handle)
    (define/public (set-handle! hdl)  (set! handle hdl))

    ; ---- identity / hierarchy ----
    (define/public (get-eventspace)   eventspace)
    (define/public (get-parent)       parent)
    ; NOTE: set-area-parent is intentionally NOT here.
    ; It is added by make-item% via public* in wxitem.rkt.

    ; ---- geometry ----
    (define/public (get-x)            x-pos)
    (define/public (get-y)            y-pos)
    (define/public (get-width)        w)
    (define/public (get-height)       h)
    (define/public (get-client-size xb yb)
      (set-box! xb w) (set-box! yb h))
    (define/public (get-size xb yb)
      (set-box! xb w) (set-box! yb h))
    (define/public (set-size x y nw nh)
      (when x  (set! x-pos x))
      (when y  (set! y-pos y))
      (when (and nw (> nw 0)) (set! w nw))
      (when (and nh (> nh 0)) (set! h nh)))
    (define/public (move x y)
      (set! x-pos x) (set! y-pos y))
    (define/public (center dir [parent #f]) (void))

    ; ---- visibility / enable ----
    (define/public (is-shown-to-root?)   shown?)
    (define/public (is-enabled-to-root?) enabled?)
    (define/public (is-window-enabled?) enabled?)
    (define/public (enable b)            (set! enabled? (and b #t)))
    (define/public (show on?)            (set! shown? (and on? #t)))
    (define/public (is-shown?)           shown?)
    (define/public (parent-enable on?)   (void))

    ; ---- focus / keyboard / mouse callbacks ----
    (define/public (on-set-focus)        (void))
    (define/public (on-kill-focus)       (void))
    (define/public (on-char e)           (void))
    (define/public (on-event e)          (void))
    (define/public (on-size nw nh)       (void))
    (define/public (pre-on-char w e)     #f)
    (define/public (pre-on-event w e)    #f)
    (define/public (on-drop-file f)      (void))
    (define/public (drag-accept-files on?) (void))

    ; ---- misc platform callbacks ----
    ; frame/dialog platform interface — also needed by stub dialog%
    (define/public (on-close)            #t)
    (define/public (on-activate on?)     (void))
    (define/public (display-changed)     (void))
    (define/public (enforce-size min-x min-y max-x max-y inc-x inc-y) (void))
    (define/public (get-focus-window [even-if-not-active? #f]) #f)
    (define/public (iconized?)           #f)
    (define/public (maximize on?)        (void))
    (define/public (is-maximized?)       #f)
    (define/public (fullscreen on?)      (void))
    (define/public (fullscreened?)       #f)
    (define/public (set-menu-bar mb)     (void))
    (define/public (set-modified m)      (void))
    (define/public (set-resize-corner on?) (void))
    (define/public (on-menu-command id)  (void))
    (define/public (on-menu-click)       (void))
    (define/public (on-toolbar-click)    (void))
    (define/public (on-mdi-activate on?) (void))
    (define/public (set-wait-cursor-mode on?) (void))
    (define/public (refresh)             (void))
    (define/public (queue-on-size)       (void))
    ; set-label/get-label are NOT here — they're defined in subclasses
    ; (frame%, button%, make-stub-class controls) since canvas/panel don't need them
    (define/public (skip-enter-leave-events skip?) (void))
    (define/public (set-event-positions-wrt c) (void))
    (define/public (set-cursor c)        (void))
    (define/public (reset-cursor default) (void))
    (define/public (frame-relative-dialog-status win) #f)
    ; show-control: NOT here — added by make-top-container% (wxtop.rkt) via public*
    (define/public (client-to-screen xb yb) (void))
    (define/public (screen-to-client xb yb) (void))
    (define/public (is-frame?)           #f)
    (define/public (gets-focus?)         #f)
    (define/public (set-focus)            (void))
    (define/public (register-child child on?) (void))
    (define/public (show-children)       (void))
    (define/public (paint-children)      (void))
    (define/public (get-top-frame)       this)

    ; ---- Qt-specific ----
    (define/public (get-qt-handle)       handle)

    (super-new)))
