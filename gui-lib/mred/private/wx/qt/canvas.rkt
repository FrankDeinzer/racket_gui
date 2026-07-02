#lang racket/base
; Qt canvas% — QWidget-backed canvas with Cairo-via-bitmap dc.
;
; Class hierarchy after wrapping by wxcanvas.rkt:
;   make-canvas-glue%(make-control%(canvas%(canvas-mixin(base-canvas%))))
;
; canvas-mixin (from common/canvas-mixin.rkt) provides queue-paint and
; the do-on-paint dispatch.  The platform canvas (this file) provides:
;   queue-canvas-refresh-event, request-canvas-flush-delay,
;   cancel-canvas-flush-delay, on-paint, queue-backing-flush,
;   get-dc, get-canvas-background-for-backing, skip-pre-paint?,
;   worthwhile-to-paint?
;
; After make-canvas-glue% wraps us, `on-paint` is overridden to call
; (send mred on-paint) which eventually calls the user's paint-callback.
(require racket/class
         racket/draw
         ffi/unsafe/atomic
         "../common/canvas-mixin.rkt"
         "../common/backing-dc.rkt"
         "../common/queue.rkt"
         "../common/event.rkt"
         "window.rkt"
         "utils.rkt"
         "key-map.rkt")

(provide canvas%)

; ---- Qt-specific backing dc -------------------------------------------

(define qt-dc%
  (class backing-dc%
    (init-field qt-canvas)  ; the qt-base-canvas% instance
    (inherit on-backing-flush)

    (define/override (get-backing-size wb hb)
      (let ([hdl (send qt-canvas get-handle)])
        (set-box! wb (max 1 (shim_canvas_get_width  hdl)))
        (set-box! hb (max 1 (shim_canvas_get_height hdl)))))

    (define/override (queue-backing-flush)
      (on-backing-flush
       (lambda (bm)
         (when (is-a? bm bitmap%)
           (let* ([w    (send bm get-width)]
                  [h    (send bm get-height)]
                  [buf  (make-bytes (* w h 4))]
                  [hdl  (send qt-canvas get-handle)])
             (send bm get-argb-pixels 0 0 w h buf #f #t)
             (shim_canvas_blit_argb    hdl buf w h (* w 4))
             (shim_canvas_request_repaint hdl)))))
      (void))

    (super-new [transparent? #f])))

; ---- base canvas class (inner, wrapped by canvas-mixin) ---------------

(define base-canvas%
  (class window%
    ; Init args as received after make-item% consumes window-style:
    ;   parent x y w h style [ignored-name] [gl-conf]
    (init parent x y w h style
          [ignored-name #f]
          [gl-conf      #f])

    (define the-eventspace (current-eventspace))
    (define the-parent     parent)

    ; expose-cb fires when Qt issues a showEvent or resizeEvent.
    ; It runs #:atomic? #t so we only enqueue work — no Racket calls.
    (define expose-cb
      (lambda (ud)
        ; Safely queue a paint event from inside processEvents().
        (queue-refresh-event the-eventspace
                             (lambda () (send this queue-paint)))))

    ; Parent must expose get-content-hwnd (frame% → central QWidget,
    ; panel% → panel QWidget).
    (define parent-handle
      (if (and parent (object? parent) (is-a? parent window%))
          (send parent get-content-hwnd)
          (error 'qt-canvas% "parent must be a Qt window%; got ~a" parent)))

    (define qt-handle (shim_canvas_create parent-handle expose-cb #f))

    ; ---- Input callbacks (D-1) ------------------------------------------
    ; All callbacks run #:atomic? #t — they only post events, never call
    ; Racket handlers directly.

    ; Mouse callback: type(0=press,1=release,2=move,3=enter,4=leave), x, y,
    ;   buttons, mods.
    ; For press/release: buttons = exactly one bit (the triggering button).
    ; For move/enter/leave: buttons = all currently held buttons.
    (define mouse-cb
      (lambda (ud type x y buttons mods)
        (define left?   (qt-buttons->left?   buttons))
        (define middle? (qt-buttons->middle? buttons))
        (define right?  (qt-buttons->right?  buttons))
        (define event-type
          (case type
            [(0) (cond [left?   'left-down]
                       [middle? 'middle-down]
                       [right?  'right-down]
                       [else    'left-down])]
            [(1) (cond [left?   'left-up]
                       [middle? 'middle-up]
                       [right?  'right-up]
                       [else    'left-up])]
            [(2) 'motion]
            [(3) 'enter]
            [(4) 'leave]
            [else 'motion]))
        ; For release: the button is no longer down — invert sense.
        (define left-down?   (if (= type 1) (not left?)   left?))
        (define middle-down? (if (= type 1) (not middle?) middle?))
        (define right-down?  (if (= type 1) (not right?)  right?))
        (define e
          (new mouse-event%
               [event-type  event-type]
               [left-down   left-down?]
               [middle-down middle-down?]
               [right-down  right-down?]
               [x x] [y y]
               [shift-down   (qt-mods->shift?   mods)]
               [control-down (qt-mods->control? mods)]
               [meta-down    (qt-mods->meta?    mods)]
               [alt-down     (qt-mods->alt?     mods)]))
        (queue-event the-eventspace
                     (lambda () (send this dispatch-on-event e #f)))))

    ; Key: type(0=press,1=release), Qt::Key, text-char(unicode), mods
    (define key-cb
      (lambda (ud type key text-char mods)
        (define kc (qt-key->racket-keycode key text-char))
        (when kc
          (define is-up? (= type 1))
          (define e
            (new key-event%
                 ; Release events carry the 'release symbol as key-code (per
                 ; racket/gui contract); the real key goes in key-release-code.
                 [key-code     (if is-up? 'release kc)]
                 [shift-down   (qt-mods->shift?   mods)]
                 [control-down (qt-mods->control? mods)]
                 [meta-down    (qt-mods->meta?    mods)]
                 [alt-down     (qt-mods->alt?     mods)]))
          (when is-up?
            (send e set-key-release-code kc))
          (queue-event the-eventspace
                       (lambda () (send this dispatch-on-char e #f))))))

    ; Focus: gained(1=in, 0=out)
    (define focus-cb
      (lambda (ud gained)
        (if (= gained 1)
            (queue-event the-eventspace (lambda () (send this on-set-focus)))
            (queue-event the-eventspace (lambda () (send this on-kill-focus))))))

    (shim_canvas_set_mouse_cb qt-handle mouse-cb #f)
    (shim_canvas_set_key_cb   qt-handle key-cb   #f)
    (shim_canvas_set_focus_cb qt-handle focus-cb #f)

    (super-new [handle     qt-handle]
               [parent     parent]
               [eventspace the-eventspace])

    ; Seed window%'s w/h from init args so get-size() is consistent with
    ; admin.get-view() before layout runs. Without this, make-editor-canvas%'s
    ; update-size computes (h - ch) < 0 when h=0 and ch=positive.
    ; NOTE: get-width/get-height are NOT overridden here — window%'s stored
    ; values (initially 0) ensure same-dimension? sees a change and calls super.
    (when (and (integer? w) (> w 0) (integer? h) (> h 0))
      (send this set-size (if (and (integer? x) (>= x 0)) x 0)
                          (if (and (integer? y) (>= y 0)) y 0)
                          w h))

    (define dc (new qt-dc% [qt-canvas this]))

    ; ---- canvas-mixin required interface ----

    (define/public (queue-canvas-refresh-event thunk)
      (qt-queue-window-refresh-event this thunk))

    (define/public (request-canvas-flush-delay)  #f)
    (define/public (cancel-canvas-flush-delay r)  (void))

    ; on-paint: default no-op; overridden by make-canvas-glue% to route
    ; to (send mred on-paint).
    (define/public (on-paint) (void))

    ; queue-backing-flush: canvas-mixin calls this after on-paint.
    ; The dc's own queue-backing-flush (qt-dc%) does the actual blit.
    (define/public (queue-backing-flush)
      (send dc queue-backing-flush))

    (define/public (get-dc) dc)

    (define/public (get-canvas-background-for-backing) #f)
    (define/public (skip-pre-paint?)       #f)
    (define/public (worthwhile-to-paint?)  (send this is-shown-to-root?))

    ; ---- sizing ----

    ; Forward Racket's layout-computed geometry to Qt.
    (define/override (set-size x y nw nh)
      (super set-size x y nw nh)
      (when (and nw (> nw 0) nh (> nh 0))
        (shim_widget_set_geometry qt-handle
                                  (if (and x (>= x 0)) x 0)
                                  (if (and y (>= y 0)) y 0)
                                  nw nh)))

    (define/override (get-client-size wb hb)
      (set-box! wb (max 1 (shim_canvas_get_width  qt-handle)))
      (set-box! hb (max 1 (shim_canvas_get_height qt-handle))))

    ; ---- visibility ----

    (define/override (show on?)
      (super show on?))

    (define/override (refresh)
      (send this queue-paint))

    ; ---- extras required by make-item% and glue layer ----

    (define/override (get-qt-handle)   qt-handle)
    (define/override (get-top-frame)
      (let loop ([p the-parent])
        (if (and p (object? p) (is-a? p window%))
            (let ([pp (send p get-parent)])
              (if pp (loop pp) p))
            #f)))

    ; Compatibility stubs for wx-make-window% / make-item%
    (define/public  (direct-show on?) (send this show on?))
    (define/override (is-shown?)      (send this is-shown-to-root?))
    (define/override (get-content-hwnd) qt-handle)
    (define/public  (schedule-periodic-backing-flush) (void))
    (define/public  (queue-paint)          (void))
    (define/override (paint-children)      (void))
    (define/public  (do-canvas-backing-flush ctx) (void))

    ; make-compatible-bitmap: used by canvas% to make off-screen bitmaps
    (define/public (make-compatible-bitmap w h)
      (make-object bitmap% (max 1 w) (max 1 h) #f #t))

    (define/public (get-scaled-client-size)
      (let ([wb (box 0)] [hb (box 0)])
        (get-client-size wb hb)
        (values (unbox wb) (unbox hb))))

    (define/public (begin-refresh-sequence) (void))
    (define/public (end-refresh-sequence)   (void))
    (define/public (flush)
      (shim_canvas_request_repaint qt-handle))
    (define bg-col (make-object color% "white"))
    (define/public (get-canvas-background) bg-col)
    (define/public (set-canvas-background c) (set! bg-col c))
    (define/override (set-resize-corner on?) (void))
    ; NOTE: min-client-width and min-client-height are NOT defined here.
    ; They are added by make-item% via public* as case-lambda parameters.

    ; Scroll stubs — no scrollbars in the spike
    (define/public (get-scroll-pos which)           0)
    (define/public (set-scroll-pos which v)         (void))
    (define/public (get-scroll-page which)          0)
    (define/public (set-scroll-page which v)        (void))
    (define/public (get-scroll-range which)         0)
    (define/public (set-scroll-range which v)       (void))
    (define/public (show-scrollbars h? v?)          (void))
    (define/override (set-focus)
      (shim_widget_set_focus qt-handle))
    (define/public (set-wheel-steps-mode mode)      (void))
    ; Additional platform callbacks required by wxcanvas.rkt's override*
    (define/public (on-scroll e)             (void))
    ; on-popup: override* target in make-canvas-glue% (wxcanvas.rkt:74)
    (define/public (on-popup)                (void))
    ; NOTE: on-container-resize must NOT be here — make-item% adds it via
    ;   public* (wxitem.rkt:177); make-editor-canvas% then overrides it.
    ; NOTE: on-scroll-on-change must NOT be here — wx:editor-canvas% (wxme)
    ;   adds it via define/public; make-editor-canvas% then overrides it.

    ; Combo-box interface — wxtextfield.rkt creates a wx-text-editor-canvas%
    ; subclass that overrides on-combo-select, and calls the others on `c`.
    (define/public (on-combo-select i)    (void))
    (define/public (popup-combo)          (void))
    (define/public (clear-combo-items)    (void))
    (define/public (append-combo-item s)  #f)
    (define/public (set-combo-text t)     (void))))

; ---- canvas% = canvas-mixin applied to base-canvas% --------------------

(define canvas%
  (canvas-mixin
   (canvas-autoscroll-mixin
    base-canvas%)))
