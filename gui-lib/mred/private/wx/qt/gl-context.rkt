#lang racket/base
;; canvas% 'gl for the Qt backend (docs/HACKING.md §78).
;;
;; The shim owns a QOpenGLContext on a QOffscreenSurface plus two FBOs
;; (shim_canvas_gl_create).  call-as-current makes it current with the `back`
;; FBO bound; swap-buffers blits back -> front, reads front back into the
;; canvas' QImage backing and schedules a repaint (shown on the next
;; shim_pump).  Nothing calls back into Racket (Regel 1/2).
;;
;; Degradation: with an old shim, a shim built without Qt6::OpenGL, or when no
;; context can be created, the handle is #f, the canvas stays a plain raster
;; canvas and get-gl-context answers #f (the pre-§78 behaviour).
(require racket/class
         (prefix-in draw: racket/draw/private/gl-context)
         racket/draw/private/gl-config
         "utils.rkt")

(provide (protect-out create-canvas-gl-child
                      qt-gl-context%))

;; Returns the GL child handle (or #f) for a canvas widget handle.
(define (create-canvas-gl-child canvas-handle conf)
  (let ([conf (or conf (new gl-config%))])
    (shim_canvas_gl_create canvas-handle
                           (send conf get-depth-size)
                           (send conf get-stencil-size)
                           (send conf get-multisample-size)
                           (if (send conf get-legacy?) 1 0)
                           (if (send conf get-double-buffered) 1 0))))

(define qt-gl-context%
  (class draw:gl-context%
    (init-field gl                 ; shim GL handle (RacketGL*)
                double-buffered?)

    (define/override (get-handle) (shim_gl_get_handle gl))
    (define/override (ok?) (= 1 (shim_gl_is_valid gl)))

    ;; Like gtk's glXMakeCurrent / glXMakeCurrent(None) pair.  A single-
    ;; buffered config has no swap step, so its drawing is presented when the
    ;; thunk is left (a native single-buffered window shows it immediately).
    (define/override (draw:do-call-as-current t)
      (dynamic-wind
       (lambda () (shim_gl_make_current gl))
       t
       (lambda ()
         (unless double-buffered? (shim_gl_swap gl))
         (shim_gl_done_current gl))))

    (define/override (draw:do-swap-buffers)
      (shim_gl_swap gl)
      (void))

    (super-new)))
