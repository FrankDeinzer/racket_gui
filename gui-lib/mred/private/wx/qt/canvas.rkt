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
         ffi/unsafe/collect-callback
         "../common/canvas-mixin.rkt"
         "../common/backing-dc.rkt"
         "../common/queue.rkt"
         "../common/event.rkt"
         "../../lock.rkt"
         "window.rkt"
         "panel.rkt"
         "utils.rkt"
         "key-map.rkt"
         "gcwin.rkt")

(provide canvas%
         canvas-panel%)

; ---- Qt-specific backing dc -------------------------------------------

; ---- combo-field% arrow strip (Block D backlog, §2.6) ------------------
; gtk packs a native GtkComboBox button next to the editor canvas; here the
; strip is the rightmost `combo-arrow-width` pixels of the canvas widget.
; get-client-size excludes it (so wxtextfield.rkt's pre-on-event sees a
; button-down at x > client width and opens the popup, exactly as on gtk),
; and qt-dc% paints the arrow into that strip of every flushed frame.  No
; child widget on purpose: a QPushButton would join the Tab chain and steal
; Return via setAutoDefault (Block D), and the shim has no focus-policy export.
(define combo-arrow-width 18)

(define (draw-combo-arrow-argb aw h)
  (define bm (make-bitmap aw h #f))
  (define bdc (new bitmap-dc% [bitmap bm]))
  (send bdc set-pen "white" 0 'transparent)
  (send bdc set-brush (make-object color% 240 240 240) 'solid)
  (send bdc draw-rectangle 0 0 aw h)
  (send bdc set-pen (make-object color% 160 160 160) 1 'solid)
  (send bdc draw-line 0 0 0 (sub1 h))
  (send bdc set-pen "white" 0 'transparent)
  (send bdc set-brush (make-object color% 64 64 64) 'solid)
  (let ([cx (quotient aw 2)] [cy (quotient h 2)])
    (send bdc draw-polygon (list (cons (- cx 4) (- cy 2))
                                 (cons (+ cx 4) (- cy 2))
                                 (cons cx (+ cy 3)))))
  (send bdc set-bitmap #f)
  (let ([buf (make-bytes (* aw h 4))])
    (send bm get-argb-pixels 0 0 aw h buf #f #t)
    buf))

(define qt-dc%
  (class backing-dc%
    (init-field qt-canvas)  ; the qt-base-canvas% instance
    (inherit on-backing-flush)

    ; Last arrow image, keyed by height: the strip is repainted on every
    ; flush, but only changes when the canvas is resized.
    (define arrow-h #f)
    (define arrow-buf #f)
    ; 'border / 'control-border: gtk (wx/gtk/canvas.rkt has-border?) frames the
    ; canvas -- text-field%, combo-field%, editor-canvas% and plain canvases with
    ; those flags.  Qt widgets have no frame of their own, so a 1 px outline is
    ; written over the outermost pixel ring of every flushed frame (sweep finding,
    ; tests/sweep/gallery.rkt).  ARGB, alpha first.
    (define (paint-border! buf w h)
      (when (send qt-canvas has-border?)
        (define (px! x y)
          (define i (* 4 (+ (* y w) x)))
          (bytes-set! buf i 255) (bytes-set! buf (+ i 1) 118)
          (bytes-set! buf (+ i 2) 118) (bytes-set! buf (+ i 3) 118))
        (for ([x (in-range w)]) (px! x 0) (px! x (sub1 h)))
        (for ([y (in-range h)]) (px! 0 y) (px! (sub1 w) y))))
    (define (paint-combo-strip! buf w h)
      (define aw (send qt-canvas combo-strip-width))
      (when (and (> aw 0) (> w aw))
        (unless (eqv? arrow-h h)
          (set! arrow-buf (draw-combo-arrow-argb aw h))
          (set! arrow-h h))
        (for ([y (in-range h)])
          (bytes-copy! buf (* 4 (+ (* y w) (- w aw)))
                       arrow-buf (* 4 y aw) (* 4 (add1 y) aw)))))

    (define/override (get-backing-size wb hb)
      (let ([hdl (send qt-canvas get-handle)])
        (set-box! wb (max 1 (shim_canvas_get_width  hdl)))
        (set-box! hb (max 1 (shim_canvas_get_height hdl)))))

    (define/override (queue-backing-flush)
      ; Redraw-bug measurement (2026-07-09_prompt), discriminator 3: does
      ; on-backing-flush actually hand us a bitmap (full repaint happened),
      ; or does nothing arrive (nothing-to-draw-proc, e.g. no-op erase)?
      (when (getenv "PLT_QT_DEBUG")
        (eprintf "[qt-dc] queue-backing-flush called\n"))
      (on-backing-flush
       (lambda (bm)
         (when (is-a? bm bitmap%)
           (let* ([w    (send bm get-width)]
                  [h    (send bm get-height)]
                  [buf  (make-bytes (* w h 4))]
                  [hdl  (send qt-canvas get-handle)])
             (when (getenv "PLT_QT_DEBUG")
               (eprintf "[qt-dc] on-backing-flush proc fired, bm=~ax~a\n" w h))
             (send bm get-argb-pixels 0 0 w h buf #f #t)
             (paint-combo-strip! buf w h)
             (paint-border! buf w h)
             (shim_canvas_blit_argb   hdl buf w h (* w 4))
             (shim_canvas_request_repaint hdl))))
       (lambda ()
         (when (getenv "PLT_QT_DEBUG")
           (eprintf "[qt-dc] on-backing-flush: nothing-to-draw\n"))))
      (void))

    (super-new [transparent? #f])))

; One wheel notch is 120 angleDelta units (Qt's documented convention).  A
; high-resolution device sends smaller increments; report at least one step so
; such a device still scrolls, matching gtk's 'integer wheel-steps mode.
(define (wheel-delta->steps d)
  (max 1 (round (/ (abs d) 120))))

; ---- base canvas class (inner, wrapped by canvas-mixin) ---------------

(define base-canvas%
  (class window%
    (inherit client-to-screen)
    ; Init args as received after make-item% consumes window-style:
    ;   parent x y w h style [ignored-name] [gl-conf]
    (init parent x y w h style
          [ignored-name #f]
          [gl-conf      #f])

    (define the-eventspace (current-eventspace))
    (define the-parent     parent)
    ; `style' is an init variable, which a method may not close over -- copy
    ; it into a field so qt-canvas-scroll-mixin can ask for it.
    (define the-style      style)
    (define the-combo?     (and (memq 'combo style) #t))
    (define the-border?    (and (or (memq 'border style) (memq 'control-border style)) #t))

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
    ; 'no-focus (status/tab canvases, tooltips...): never takes keyboard focus,
    ; like gtk (wx/gtk/canvas.rkt skips gtk_widget_set_can_focus for it).
    (when (memq 'no-focus style) (shim_widget_set_no_focus qt-handle))

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
               [meta-down    (qt-mods->meta-down? mods)]
               [mod4-down    (qt-mods->mod4-down? mods)]
               [alt-down     (qt-mods->alt-down?  mods)]))
        (queue-event the-eventspace
                     (lambda () (send this dispatch-on-event e #f)))))

    ; Key: type(0=press,1=release), Qt::Key, text-char(unicode), mods
    (define key-cb
      (lambda (ud type key text-char mods)
        (define scan (qt-mods-scancode mods))
        (set! mods (qt-mods-modifiers mods))
        (define kc (qt-key->racket-keycode key text-char mods))
        (when kc
          (define is-up? (= type 1))
          (define e
            (new key-event%
                 ; Release events carry the 'release symbol as key-code (per
                 ; racket/gui contract); the real key goes in key-release-code.
                 [key-code     (if is-up? 'release kc)]
                 [shift-down   (qt-mods->shift?   mods)]
                 [control-down (qt-mods->control? mods)]
                 [meta-down    (qt-mods->meta-down? mods)]
                 [mod4-down    (qt-mods->mod4-down? mods)]
                 [alt-down     (qt-mods->alt-down?  mods)]))
          (when (and (char? kc) (> scan 0) (eq? (system-type) 'unix))
            (let-values ([(s ag sag cl) (qt-key-alternates scan mods shim_key_keysym)])
              (when s   (send e set-other-shift-key-code s))
              (when ag  (send e set-other-altgr-key-code ag))
              (when sag (send e set-other-shift-altgr-key-code sag))
              (when cl  (send e set-other-caps-key-code cl))))
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

    ; Wheel: dx/dy in Qt angleDelta units (one notch = 120; dy > 0 = up).
    ; racket/gui delivers the wheel as a key-event% whose key-code is
    ; 'wheel-up/'wheel-down/'wheel-left/'wheel-right with a wheel-steps count
    ; -- that is what wxme/editor-canvas.rkt's on-char consumes, and what
    ; wx/gtk/window.rkt's connect-scroll produces.  Vertical wins when a
    ; single event carries both axes (a trackpad diagonal), matching gtk's
    ; y-before-x ordering.
    (define wheel-cb
      (lambda (ud dx dy mods)
        (define-values (code steps)
          (cond
            [(> dy 0) (values 'wheel-up    (wheel-delta->steps dy))]
            [(< dy 0) (values 'wheel-down  (wheel-delta->steps dy))]
            [(> dx 0) (values 'wheel-right (wheel-delta->steps dx))]
            [(< dx 0) (values 'wheel-left  (wheel-delta->steps dx))]
            [else     (values #f 0)]))
        (when code
          (define e
            (new key-event%
                 [key-code     code]
                 [shift-down   (qt-mods->shift?   mods)]
                 [control-down (qt-mods->control? mods)]
                 [meta-down    (qt-mods->meta-down? mods)]
                 [mod4-down    (qt-mods->mod4-down? mods)]
                 [alt-down     (qt-mods->alt-down?  mods)]))
          (send e set-wheel-steps steps)
          ; A scrollable canvas-panel% gets first refusal: nothing downstream
          ; of dispatch-on-char would scroll it (see qt-wheel-scroll below).
          (queue-event the-eventspace
                       (lambda ()
                         (unless (send this qt-wheel-scroll code steps)
                           (send this dispatch-on-char e #f)))))))

    (shim_canvas_set_mouse_cb qt-handle mouse-cb #f)
    (shim_canvas_set_key_cb   qt-handle key-cb   #f)
    (shim_canvas_set_focus_cb qt-handle focus-cb #f)
    (shim_canvas_set_wheel_cb qt-handle wheel-cb #f)

    (super-new [handle     qt-handle]
               [parent     parent]
               [eventspace the-eventspace]
               [no-show?   (and (memq 'deleted style) #t)])

    ; Must exist before the set-size seed call below: that override now also
    ; touches `dc' (reset-backing-retained), and set-size can run during
    ; construction.
    (define dc (new qt-dc% [qt-canvas this]))
    (send dc start-backing-retained)

    ; Seed window%'s w/h from init args so get-size() is consistent with
    ; admin.get-view() before layout runs. Without this, make-editor-canvas%'s
    ; update-size computes (h - ch) < 0 when h=0 and ch=positive.
    ; NOTE: get-width/get-height are NOT overridden here — window%'s stored
    ; values (initially 0) ensure same-dimension? sees a change and calls super.
    (when (and (integer? w) (> w 0) (integer? h) (> h 0))
      (send this set-size (if (and (integer? x) (>= x 0)) x 0)
                          (if (and (integer? y) (>= y 0)) y 0)
                          w h))

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

    ; Mirrors gtk/win32/cocoa's (and clear-bg? bg-col): the regular auto-repaint
    ; path (canvas-mixin.rkt's do-on-paint) uses this to fill the backing bitmap
    ; before the user's on-paint runs. Was unconditionally #f, so set-canvas-background
    ; had no effect on the auto-clear -- masked by editor-canvas%/full-repaint canvases,
    ; visible on a raw canvas% with a non-covering paint callback (§61).
    (define/public (get-canvas-background-for-backing)
      (and (not (memq 'transparent the-style))
           (not (memq 'no-autoclear the-style))
           bg-col))
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
                                  nw nh)
        ; The retained backing bitmap (start-backing-retained, above) is sized
        ; from get-backing-size at its first get-cr call. Without a reset here,
        ; a bitmap created before layout assigns the real size (e.g. a 1x1 or
        ; 30x30 placeholder) would stay retained at that wrong size forever.
        ; win32/gtk do the same on their own resize hooks (on-resized/
        ; internal-on-client-size -> reset-dc -> reset-backing-retained).
        (send dc reset-backing-retained)))

    ; `on-size' exists for editor-canvas% only, exactly as in wx/win32/canvas.rkt
    ; and wx/gtk/canvas.rkt: those backends call it from their own set-size.
    ; Here the call sits in qt-canvas-scroll-mixin (below), because the
    ; autoscroll state it guards on lives in a class *above* base-canvas%.
    ; NOTE: this overrides window%'s two-argument `on-size' stub (which has no
    ; callers) with the zero-argument shape editor-canvas% overrides.
    (define/override (on-size) (void))
    (define/public (is-panel?) #f)

    ; qt-canvas-scroll-mixin needs the style list, but cannot declare its own
    ; `init' without breaking the by-position init-arg pass-through that the
    ; mixin chain relies on.
    (define/public (get-canvas-style) the-style)

    (define/override (get-client-size wb hb)
      (set-box! wb (max 1 (- (shim_canvas_get_width qt-handle)
                             (combo-strip-width))))
      (set-box! hb (max 1 (shim_canvas_get_height qt-handle))))

    ; Width of the combo-field% arrow strip at the right edge (0 otherwise).
    (define/public (combo-strip-width) (if the-combo? combo-arrow-width 0))
    (define/public (has-border?) the-border?)

    ; ---- visibility ----

    (define/override (show on?)
      (super show on?))

    (define/override (refresh)
      (when (getenv "PLT_QT_DEBUG")
        (eprintf "[qt-canvas] refresh -> queue-paint\n"))
      (send this queue-paint))

    ; ---- GC indicator (DrRacket's status-bar gc-canvas) ------------------
    ; wx/qt/platform.rkt's register-collecting-blit/unregister-collecting-blit
    ; delegate here, exactly as gtk/win32's own procs.rkt delegate to their
    ; canvas%'s same-named methods (docs/HACKING.md's public*/override*
    ; invariant does not apply -- these names are define/public directly on
    ; gtk's canvas% too, never public*/override*-mediated). x11-gc-available?
    ; gates the whole thing off (silent no-op) under Wayland or on a non-X11
    ; platform (Regel 4) -- see wx/qt/gcwin.rkt for the full design and the
    ; GC-safety argument for what actually runs during the callback.
    (define reg-blits null)

    (define/private (register-one-blit x y w h on-gc-bitmap off-gc-bitmap)
      (atomically
       (let ([win (create-gc-window qt-handle x y w h)])
         (let ([r (unsafe-add-collect-callbacks
                   (make-gc-show-desc win on-gc-bitmap w h)
                   (make-gc-hide-desc win off-gc-bitmap w h))])
           (cons win r)))))

    (define/public (register-collecting-blit x y w h on off on-x on-y off-x off-y)
      (when (x11-gc-available?)
        (let ([on  (fix-bitmap-size on  w h on-x on-y)]
              [off (fix-bitmap-size off w h off-x off-y)])
          (let ([on-gc-bitmap  (bitmap->gc-bitmap on  qt-handle)]
                [off-gc-bitmap (bitmap->gc-bitmap off qt-handle)])
            (atomically
             (set! reg-blits (cons (register-one-blit x y w h
                                                        on-gc-bitmap off-gc-bitmap)
                                    reg-blits)))))))

    (define/public (unregister-collecting-blits)
      (atomically
       (for ([r (in-list reg-blits)])
         (free-gc-window (car r))
         (unsafe-remove-collect-callbacks (cdr r)))
       (set! reg-blits null)))

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

    (define/public (begin-refresh-sequence)
      (when (getenv "PLT_QT_DEBUG")
        (eprintf "[qt-canvas] begin-refresh-sequence -> suspend-flush\n"))
      (send dc suspend-flush))
    (define/public (end-refresh-sequence)
      (when (getenv "PLT_QT_DEBUG")
        (eprintf "[qt-canvas] end-refresh-sequence -> resume-flush\n"))
      (send dc resume-flush))
    ; Redraw-bug measurement (2026-07-09_prompt), discriminator 3: `flush'
    ; calls request_repaint directly, bypassing queue-backing-flush/blit --
    ; if this fires during typing, Qt repaints the existing (possibly stale)
    ; backing instead of a freshly rendered one.
    (define/public (flush)
      (when (getenv "PLT_QT_DEBUG")
        (eprintf "[qt-canvas] flush -> request_repaint (NO fresh blit)\n"))
      (shim_canvas_request_repaint qt-handle))
    (define bg-col (make-object color% "white"))
    (define/public (get-canvas-background) bg-col)
    (define/public (set-canvas-background c) (set! bg-col c))
    (define/override (set-resize-corner on?) (void))
    ; NOTE: min-client-width and min-client-height are NOT defined here.
    ; They are added by make-item% via public* as case-lambda parameters.

    ; Scroll API: these defaults apply to a canvas without scrollbars.
    ; qt-canvas-scroll-mixin (below) overrides them when the style asks for
    ; scrollbars; win32/gtk carry the same no-scrollbar fallbacks inline.
    (define/public (get-scroll-pos which)           0)
    (define/public (set-scroll-pos which v)         (void))
    (define/public (get-scroll-page which)          0)
    (define/public (set-scroll-page which v)        (void))
    (define/public (get-scroll-range which)         0)
    (define/public (set-scroll-range which v)       (void))
    (define/public (show-scrollbars h? v?)          (void))
    ; Asked before the wheel is delivered as a key-event%; #t means "consumed".
    ; Only qt-canvas-scroll-mixin's scrollable-panel case ever answers #t.
    (define/public (qt-wheel-scroll code steps)     #f)
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
    ; The dropdown is one QMenu per canvas.  `combo-cbs` keeps every action
    ; callback reachable from Racket for as long as its action is attached
    ; (same GC rule as menu.rkt's retained-callbacks, §59.1); the callback only
    ; posts the selection (Rule 2).  Index = 0-based append order, which is
    ; what wxtextfield.rkt's on-combo-select maps back through its callbacks.
    ; clear-combo-items detaches the actions; QMenu has no shim-side delete,
    ; so the detached QAction objects stay allocated (a few bytes each).
    (define combo-menu #f)
    (define combo-actions null)   ; (action . callback), newest first
    (define/public (on-combo-select i)    (void))
    (define/public (popup-combo)
      (when (and combo-menu (pair? combo-actions))
        (define xb (box 0))
        (define yb (box (shim_canvas_get_height qt-handle)))
        (client-to-screen xb yb)
        (shim_menu_popup combo-menu (unbox xb) (unbox yb))))
    (define/public (clear-combo-items)
      (when combo-menu
        (for ([a (in-list combo-actions)])
          (shim_menu_remove_action combo-menu (car a))))
      (set! combo-actions null))
    (define/public (append-combo-item s)
      (unless combo-menu (set! combo-menu (shim_menu_create "")))
      (define i (length combo-actions))
      (define cb (lambda (ud)
                   (qt-queue-window-event this (lambda () (on-combo-select i)))))
      (set! combo-actions
            (cons (cons (shim_action_create combo-menu s 0 cb #f) cb)
                  combo-actions))
      #t)
    (define/public (set-combo-text t)     (void))))

; ---- qt-canvas-scroll-mixin -------------------------------------------
; Real scrollbars for canvas%, as QScrollBar children of the canvas widget.
;
; Sits between canvas-autoscroll-mixin and canvas-mixin.  It has to live here
; and not in base-canvas% for two reasons:
;   * canvas-autoscroll-mixin is applied *above* base-canvas%, so the methods
;     this class overrides (do-set-scrollbars, reset-dc-for-autoscroll,
;     get-virtual-{h,v}-pos) are define/public there and cannot be overridden
;     from below (public*/override* invariant, docs/HACKING.md §1).  win32/gtk
;     do not have this problem: there the mixin is a *superclass* of the
;     platform canvas.
;   * that same inversion means canvas-autoscroll-mixin's state does not exist
;     yet while base-canvas%'s constructor runs -- hence scroll-ready? below.
;
; Structural difference to the other backends: win32 gets its scrollbars from
; WS_HSCROLL/WS_VSCROLL window styles (non-client area) and gtk packs them as
; siblings in a box, so in both the client area shrinks by itself.  Here they
; are children of the canvas widget, so get-client-size has to subtract their
; extent explicitly.
(define (qt-canvas-scroll-mixin %)
  (class %
    (inherit is-auto-scroll? is-disabled-scroll? reset-auto-scroll
             refresh-for-autoscroll get-virtual-width get-virtual-height
             is-panel? on-size on-scroll get-canvas-style get-qt-handle
             get-dc get-eventspace refresh)

    ; Guard for the seed set-size call in base-canvas%'s constructor: that one
    ; runs inside our own (super-new), i.e. before canvas-autoscroll-mixin's
    ; fields exist.  Defined before super-new so it is readable at that point
    ; (same pattern as gtk/canvas.rkt's `dc' field).
    (define scroll-ready? #f)

    ; Separate content widget for a scrollable canvas-panel% (see below).
    ; Declared before super-new so get-content-hwnd can be answered at any
    ; point during construction; filled in once the style is known.
    (define content-handle #f)

    (super-new)

    ; Scroll tracing, off unless PLT_QT_SCROLL_DEBUG is set.  Separate from
    ; PLT_QT_DEBUG on purpose: that one also turns on the per-paint logging,
    ; which drowns the scroll sequence.  The id tags one canvas instance --
    ; a DrRacket frame has dozens, so untagged lines are unreadable.
    ; Defined here rather than next to the other internals below: `dbg' is a
    ; plain letrec-bound name (not a method), so a trace call in the class
    ; body can only see it after this point.
    (define dbg-id (gensym 'c))
    (define (dbg fmt . args)
      (when (getenv "PLT_QT_SCROLL_DEBUG")
        (apply eprintf (string-append "[sb ~a] " fmt) dbg-id args)))

    (define scroll-style (get-canvas-style))

    ; Same test as win32 (canvas.rkt:98-101, which turns it into WS_?SCROLL);
    ; canvas-panel% included, see the content widget below.
    (define want-h?
      (and (or (memq 'hscroll scroll-style) (memq 'auto-hscroll scroll-style))
           #t))
    (define want-v?
      (and (or (memq 'vscroll scroll-style) (memq 'auto-vscroll scroll-style))
           #t))

    (dbg "style=~a panel=~a want=~a/~a\n" scroll-style (is-panel?) want-h? want-v?)

    ; ---- content widget (scrollable canvas-panel% only) -----------------
    ; A panel's content is real child widgets, and a dc offset does not move
    ; those.  win32 solves it with a separate content-hwnd inside the canvas
    ; window that children parent into (canvas.rkt:149-159) and that
    ; canvas-panel%'s reset-dc-for-autoscroll moves by the scroll offset
    ; (canvas.rkt:663-673).  This is the Qt equivalent: a plain container
    ; widget handed out by get-content-hwnd and repositioned in
    ; position-content!.
    ;
    ; Two deliberate differences from win32:
    ;  * Created only for a panel that actually gets a scrollbar, not for
    ;    every is-panel?.  Every child of such a panel parents into this
    ;    handle instead of the canvas widget, so the change is kept to
    ;    'vscroll/'auto-vscroll (and the h variants) panels; the
    ;    'hide-hscroll/'hide-vscroll ones (framework/private/color-prefs.rkt's
    ;    canvas:color%) keep exactly the structure they have today.
    ;  * Created *before* the scrollbars.  Among Qt siblings the one created
    ;    last is on top, and this widget is as large as the virtual content,
    ;    so it would cover the bars if it came second.  The shim has no raise
    ;    primitive and adding one would mean a further ABI export.
    (when (and (is-panel?) (or want-h? want-v?))
      (set! content-handle (shim_panel_create (get-qt-handle) 0))
      ; Qt does not show a child that is added to an already-visible parent,
      ; and this widget is not a window%, so nothing else will ever call show
      ; on it.  Without this the whole panel stays blank.
      (shim_widget_set_visible content-handle 1))

    ; Bound to fields before being handed to the shim: an inline lambda would
    ; have no Racket-side owner, so the closure could be collected while Qt
    ; still holds the pointer (the use-after-free found and then lost with the
    ; revert in §24.5).  Same convention as mouse-cb/key-cb/focus-cb.
    (define h-changed-cb (lambda (ud) (scroll-changed 'horizontal)))
    (define v-changed-cb (lambda (ud) (scroll-changed 'vertical)))

    (define h-sb (and want-h?
                      (shim_scrollbar_create (get-qt-handle) 0 h-changed-cb #f)))
    (define v-sb (and want-v?
                      (shim_scrollbar_create (get-qt-handle) 1 v-changed-cb #f)))

    ; Thickness from the widget's own size hint, not a hard-coded number:
    ; it is style- and DPI-dependent.
    (define h-thickness
      (if h-sb (let-values ([(w h) (shim_widget_get_size_hint h-sb)]) (max 1 h)) 0))
    (define v-thickness
      (if v-sb (let-values ([(w h) (shim_widget_get_size_hint v-sb)]) (max 1 w)) 0))

    ; Start visible exactly like win32, where WS_?SCROLL makes the bar present
    ; from creation; editor-canvas% calls show-scrollbars during its own setup
    ; and corrects this immediately.
    (define h-shown? want-h?)
    (define v-shown? want-v?)

    ; Racket-side mirror of each bar's range/page/step.  Needed because the
    ; shim sets range, page and step in one call while wx hands them over
    ; separately (set-scroll-range / set-scroll-page), and because a read-back
    ; would have to cross the FFI for values we already know.  The *position*
    ; is deliberately not mirrored -- the user moves it, so Qt owns it.
    (define h-len 0)  (define v-len 0)
    (define h-page 1) (define v-page 1)
    (define h-step 1) (define v-step 1)

    (set! scroll-ready? #t)

    (when (or h-sb v-sb)
      (push-range! 'horizontal)
      (push-range! 'vertical)
      (apply-visibility!)
      (position-scrollbars!)
      (position-content!))

    ; ---- internals ------------------------------------------------------

    (define/private (sb-of which) (if (eq? which 'vertical) v-sb h-sb))

    (define/private (push-range! which)
      (define sb (sb-of which))
      (when sb
        (shim_scrollbar_set_range sb
                                  (if (eq? which 'vertical) v-len  h-len)
                                  (if (eq? which 'vertical) v-page h-page)
                                  (if (eq? which 'vertical) v-step h-step))))

    (define/private (apply-visibility!)
      (when h-sb (shim_widget_set_visible h-sb (if h-shown? 1 0)))
      (when v-sb (shim_widget_set_visible v-sb (if v-shown? 1 0))))

    ; Right edge / bottom edge of the canvas widget, leaving the corner free
    ; when both bars are up.  set-size passes the size it was handed, so the
    ; bars are placed against the same number as the rest of that call rather
    ; than against a widget geometry that may still be catching up.
    (define/private (position-scrollbars! [w0 #f] [h0 #f])
      (define hdl (get-qt-handle))
      (define w (or w0 (max 1 (shim_canvas_get_width  hdl))))
      (define h (or h0 (max 1 (shim_canvas_get_height hdl))))
      (define vt (if (and v-sb v-shown?) v-thickness 0))
      (define ht (if (and h-sb h-shown?) h-thickness 0))
      (when v-sb
        (shim_widget_set_geometry v-sb (max 0 (- w vt)) 0
                                  vt (max 1 (- h ht))))
      (when h-sb
        (shim_widget_set_geometry h-sb 0 (max 0 (- h ht))
                                  (max 1 (- w vt)) ht)))

    ; Children that a panel places live in the content widget, so the panel's
    ; scroll offset is applied by moving that one widget.  Its size is the
    ; virtual content size but never smaller than the client area -- children
    ; outside the parent's rectangle are clipped away by Qt.
    ;
    ; The base is the *client* size (bars already subtracted), not the raw
    ; widget size that position-scrollbars! works against: wxpanel.rkt's
    ; panel-redraw places its children against exactly this number, so the
    ; content widget has to agree with it.
    (define/private (position-content!)
      (when content-handle
        (define wb (box 0))
        (define hb (box 0))
        (get-client-size wb hb)
        (define vw (or (get-virtual-width)  0))
        (define vh (or (get-virtual-height) 0))
        (define cw (max 1 (unbox wb) vw))
        (define ch (max 1 (unbox hb) vh))
        (define cx (- (content-offset 'horizontal)))
        (define cy (- (content-offset 'vertical)))
        (dbg "position-content! ~a,~a ~ax~a (client ~ax~a virtual ~ax~a)\n"
             cx cy cw ch (unbox wb) (unbox hb) vw vh)
        (shim_widget_set_geometry content-handle cx cy cw ch)))

    ; A hidden bar keeps its last value.  Reading it anyway would leave the
    ; content scrolled away with nothing to scroll it back, as soon as
    ; wxpanel.rkt's adjust-panel-size decides the content fits and hides the
    ; bar.
    (define/private (content-offset which)
      (if (if (eq? which 'vertical) v-shown? h-shown?)
          (get-real-scroll-pos which)
          0))

    ; Fires from the shim's valueChanged signal, i.e. only on real user
    ; interaction: shim_scrollbar_set_range/set_value block the signal for
    ; programmatic changes (QSignalBlocker), so gtk's as-scroll-change
    ; suppression has no counterpart here.
    (define/private (scroll-changed which)
      (dbg "scroll-changed ~a -> ~a\n" which (get-real-scroll-pos which))
      (queue-event
       (get-eventspace)
       (lambda ()
         (if (is-auto-scroll?)
             (refresh-for-autoscroll)
             (on-scroll (new scroll-event%
                             [event-type 'thumb]
                             [direction  which]
                             ; scroll-event%'s position is contracted to
                             ; 0..10000 while editor-canvas% clamps its own
                             ; ranges to 10000000 -- clamp rather than raise.
                             [position   (max 0 (min 10000
                                                     (get-real-scroll-pos which)))]))))))

    (define/private (get-real-scroll-pos which)
      (define sb (sb-of which))
      (if sb (shim_scrollbar_get_value sb) 0))

    (define/private (is-disabled-scroll-dir? which)
      (or (not (sb-of which))
          (is-disabled-scroll?)))

    ; ---- sizing ---------------------------------------------------------

    ; win32 (canvas.rkt:306-309) and gtk (canvas.rkt:450-454) do exactly this.
    ; Without it editor-canvas% never learns that it was resized, so its
    ; scrollbar bookkeeping stays frozen at the construction-time placeholder
    ; geometry (docs/HACKING.md §24.5's central measurement).
    ; on-size is reported unconditionally, as in win32 (canvas.rkt:309).  A
    ; dedup on the last size was tried here -- the §32 lesson -- on the theory
    ; that the on-size -> reset-size -> scrollbar -> relayout -> set-size round
    ; trip was leaving a canvas at the wrong height.  Measured with
    ; PLT_QT_SCROLL_DEBUG: it changes nothing (the transient full-height
    ; client size it was meant to remove is just as present with the guard as
    ; without, and in runs that render correctly), so it was dropped rather
    ; than kept as unjustified state.  editor-canvas% dedups on its own
    ; anyway, in maybe-reset-size.
    (define/override (set-size x y nw nh)
      (super set-size x y nw nh)
      ; Mirrors base-canvas%'s own guard: a non-positive size carries no
      ; geometry to act on.
      (when (and scroll-ready? nw (> nw 0) nh (> nh 0))
        (position-scrollbars! nw nh)
        ; The client area just changed, so the content widget's minimum does
        ; too.  Its scroll offset is untouched here -- the panel's own
        ; relayout re-runs set-scrollbars and comes back through
        ; reset-dc-for-autoscroll.
        (position-content!)
        (when (and (is-auto-scroll?) (not (is-panel?)))
          (reset-auto-scroll))
        (on-size)))

    ; The bars sit inside the canvas widget, so they eat client area.
    (define/override (get-client-size wb hb)
      (super get-client-size wb hb)
      (dbg "get-client-size raw=~ax~a shown=~a/~a thick=~a/~a\n"
           (unbox wb) (unbox hb) h-shown? v-shown? h-thickness v-thickness)
      (when scroll-ready?
        (when (and v-sb v-shown?)
          (set-box! wb (max 1 (- (unbox wb) v-thickness))))
        (when (and h-sb h-shown?)
          (set-box! hb (max 1 (- (unbox hb) h-thickness))))))

    ; ---- wx scroll API --------------------------------------------------

    (define/override (show-scrollbars h? v?)
      (define new-h? (and h? want-h? #t))
      (define new-v? (and v? want-v? #t))
      (dbg "show-scrollbars ~a ~a (was ~a ~a)\n" new-h? new-v? h-shown? v-shown?)
      ; Dedup as in win32 (canvas.rkt:414-417).  editor-canvas%'s reset-size
      ; re-runs itself whenever the bars change, so an unconditional update
      ; here would keep re-triggering that loop.
      (unless (and (eq? new-h? h-shown?) (eq? new-v? v-shown?))
        (set! h-shown? new-h?)
        (set! v-shown? new-v?)
        (apply-visibility!)
        (position-scrollbars!)
        (position-content!)
        ; Client size just changed, so the retained backing is the wrong size.
        ; The repaint request is not optional: nothing else is guaranteed to
        ; follow show-scrollbars, and an invalidated backing with no repaint
        ; leaves the canvas blank.  win32 does both in its reset-dc
        ; (canvas.rkt:276-285, called from show-scrollbars at :426).
        (send (get-dc) reset-backing-retained)
        (refresh)))

    (define/override (do-set-scrollbars hs vs h-l v-l h-p v-p h-pos v-pos)
      (dbg "do-set-scrollbars step=~a/~a len=~a/~a page=~a/~a pos=~a/~a\n"
           hs vs h-l v-l h-p v-p h-pos v-pos)
      (set! h-step (max 1 hs)) (set! v-step (max 1 vs))
      (set! h-len h-l)         (set! v-len v-l)
      (set! h-page (max 1 h-p)) (set! v-page (max 1 v-p))
      (push-range! 'horizontal)
      (push-range! 'vertical)
      ; -1 means "keep the current position" (see gtk's configure-adj).
      (when (and h-sb (>= h-pos 0)) (shim_scrollbar_set_value h-sb h-pos))
      (when (and v-sb (>= v-pos 0)) (shim_scrollbar_set_value v-sb v-pos)))

    ; Gating mirrors win32/gtk exactly: in auto-scroll mode the canvas-level
    ; scroll API reports zero and view-start/get-virtual-*-pos are used
    ; instead.  editor-canvas% relies on this.
    (define/override (get-scroll-pos which)
      (if (or (is-disabled-scroll-dir? which) (is-auto-scroll?))
          0
          (get-real-scroll-pos which)))
    (define/override (set-scroll-pos which v)
      (dbg "set-scroll-pos ~a ~a\n" which v)
      (define sb (sb-of which))
      (when sb (shim_scrollbar_set_value sb v)))

    (define/override (get-scroll-range which)
      (if (or (is-disabled-scroll-dir? which) (is-auto-scroll?))
          0
          (if (eq? which 'vertical) v-len h-len)))
    (define/override (set-scroll-range which v)
      (dbg "set-scroll-range ~a ~a\n" which v)
      (if (eq? which 'vertical) (set! v-len v) (set! h-len v))
      (push-range! which))

    (define/override (get-scroll-page which)
      (if (or (is-disabled-scroll-dir? which) (is-auto-scroll?))
          0
          (if (eq? which 'vertical) v-page h-page)))
    (define/override (set-scroll-page which v)
      (dbg "set-scroll-page ~a ~a\n" which v)
      (if (eq? which 'vertical) (set! v-page (max 1 v)) (set! h-page (max 1 v)))
      (push-range! which))

    ; ---- auto-scroll ----------------------------------------------------
    ; Two kinds of content arrive here.  A plain canvas% with an
    ; 'auto-?scroll style paints itself, so a dc offset is all it needs.  A
    ; canvas-panel% holds real child widgets, which no dc offset can move --
    ; for those the content widget is moved instead (position-content!),
    ; exactly as win32's canvas-panel% moves its content-hwnd.

    (define/override (get-virtual-h-pos) (get-real-scroll-pos 'horizontal))
    (define/override (get-virtual-v-pos) (get-real-scroll-pos 'vertical))

    ; The wheel over a scrollable canvas-panel%.  For every other canvas the
    ; wheel arrives as a key-event% and something downstream turns it into
    ; scrolling -- editor-canvas% does exactly that (wxme/editor-canvas.rkt:
    ; 506).  A panel has no editor and its mred-side on-char ignores the code,
    ; so the event would simply be dropped: gtk scrolls such a panel from its
    ; scrolled window and win32 from the scrollbar's own window messages,
    ; while here the canvas widget is the only thing the event reaches.
    (define/override (qt-wheel-scroll code steps)
      (define which (case code
                      [(wheel-up wheel-down)    'vertical]
                      [(wheel-left wheel-right) 'horizontal]
                      [else                     #f]))
      ; Gated on content-handle rather than on (is-auto-scroll?): that flag is
      ; only set once wxpanel.rkt's panel-redraw has run set-scrollbars for
      ; the first time, and a wheel event arriving before that would fall
      ; through and be dropped.  content-handle is the precise condition --
      ; it exists exactly for a panel that this class scrolls itself, and it
      ; keeps editor-canvas% (never a panel) out.
      (define sb (and which
                      content-handle
                      (if (eq? which 'vertical)
                          (and v-shown? v-sb)
                          (and h-shown? h-sb))))
      (and sb
           (let* ([page  (if (eq? which 'vertical) v-page h-page)]
                  ; A tenth of a page per notch.  Deferring to the bar's own
                  ; single step is not an option here: reset-auto-scroll hands
                  ; out `1 1' as the step, and Qt multiplies that by
                  ; wheelScrollLines -- measured over the bar itself, that is
                  ; 3 px a notch against a range of several hundred.
                  [delta (* (max 1 (quotient page 10))
                            (max 1 (inexact->exact (round steps))))]
                  [dir   (if (memq code '(wheel-up wheel-left)) -1 1)])
             (dbg "qt-wheel-scroll ~a ~a steps -> ~a px\n" code steps (* dir delta))
             (shim_scrollbar_set_value sb (max 0 (+ (get-real-scroll-pos which)
                                                    (* dir delta))))
             ; set_value blocks valueChanged (QSignalBlocker), so the move has
             ; to be reported by hand -- the same path a thumb drag takes.
             (scroll-changed which)
             #t)))

    ; get-content-hwnd is what a child asks its parent for at construction
    ; time (base-canvas%, panel%, button% ... all do), so this is the single
    ; point that puts a scrollable panel's children into the moving widget.
    (define/override (get-content-hwnd)
      (or content-handle (super get-content-hwnd)))

    ; Sign convention: set-auto-scroll negates internally (draw-lib
    ; dc.rkt:466-471), so the raw scroll position goes in -- same as win32
    ; (canvas.rkt:278-284), whose gating on get-virtual-width/height this
    ; mirrors as well.
    (define/override (reset-dc-for-autoscroll)
      (define dc (get-dc))
      ; The panel half of the scroll: move the child widgets.  A no-op for a
      ; canvas without a content widget.
      (position-content!)
      (send dc reset-backing-retained)
      (send dc set-auto-scroll
            (if (get-virtual-width)  (get-virtual-h-pos) 0)
            (if (get-virtual-height) (get-virtual-v-pos) 0))
      ; As in win32 (canvas.rkt:445-447): refresh here, because
      ; canvas-autoscroll-mixin's set-scrollbars calls this one directly when
      ; auto-scroll is switched off, without a refresh of its own.
      (refresh))))

; ---- canvas% = canvas-mixin applied to base-canvas% --------------------

(define canvas%
  (canvas-mixin
   (qt-canvas-scroll-mixin
    (canvas-autoscroll-mixin
     base-canvas%))))

; ---- canvas-panel% = canvas% + panel-mixin -----------------------------
; A scrollable canvas that also hosts children (e.g. framework/private/
; color-prefs.rkt's hide-hscroll/hide-vscroll preference panels) -- mirrors
; win32's canvas-panel% (wx/win32/canvas.rkt), which is likewise just
; canvas% + panel-mixin. set-scrollbars/do-set-scrollbars/
; reset-dc-for-autoscroll/get-virtual-h-pos/get-virtual-v-pos all already
; come from canvas%'s own canvas-autoscroll-mixin composition above -- the
; only thing missing for a plain canvas% to also work as a panel is
; panel-mixin's adopt-child/register-child/etc (docs/HACKING.md §22).
;
; The separate content widget that win32's canvas-panel% keeps (and moves in
; its reset-dc-for-autoscroll) lives in qt-canvas-scroll-mixin here rather
; than in this class: it has to be created before the scrollbars to end up
; below them in Qt's sibling stacking order, and only that mixin runs early
; enough.  win32's other canvas-panel% override, notify-child-extent, has no
; counterpart -- it is called from win32 window%'s own resize path, which this
; backend's window.rkt does not have; the content widget is instead sized from
; canvas-autoscroll-mixin's virtual size, which wxpanel.rkt's panel-redraw
; sets (via set-scrollbars) before it places any child.
(define canvas-panel%
  (class (panel-mixin canvas%)
    (define/override (is-panel?) #t)
    (super-new)))
