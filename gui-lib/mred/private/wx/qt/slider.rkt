#lang racket/base
; Qt slider% — wraps a QSlider via the shim.
; Init args mirror wx/win32 + wx/gtk's slider%, as received from
; wxlitem.rkt's wx-internal-slider% after make-control% consumes
; window-style: parent cb label val lo hi x y w style font.
(require racket/class
         "../common/event.rkt"
         "../common/queue.rkt"
         "window.rkt"
         "utils.rkt")

(provide slider%)

(define slider%
  (class window%
    (init parent cb label val lo hi x y w style font)

    (define the-eventspace (current-eventspace))
    (define the-parent parent)
    (define callback cb)

    ; changed-fn captures `this`; runs later in atomic + queued context.
    (define changed-fn
      (lambda (ud)
        (queue-event the-eventspace
                     (lambda ()
                       (callback this
                                 (make-object control-event% 'slider))))))

    (define parent-handle
      (if (and parent (object? parent) (is-a? parent window%))
          (send parent get-content-hwnd)
          (error 'qt-slider% "parent must be a Qt window%; got ~a" parent)))

    (define qt-handle
      (shim_slider_create parent-handle
                          (if (or (memq 'vertical style) (memq 'upward style)) 1 0)
                          lo hi val
                          changed-fn
                          #f))

    (super-new [handle     qt-handle]
               [parent     parent]
               [eventspace the-eventspace])
    (send this seed-size-from-native-hint)

    ; ---- sizing ----

    (define/override (set-size x y nw nh)
      (super set-size x y nw nh)
      (when (and nw (> nw 0) nh (> nh 0))
        (shim_widget_set_geometry qt-handle
                                  (if (and x (>= x 0)) x 0)
                                  (if (and y (>= y 0)) y 0)
                                  nw nh)))

    ; ---- value protocol (slider% contract, mirrors gtk/win32) ----

    (define/public (set-value v)
      (shim_slider_set_value qt-handle v))

    (define/public (get-value)
      (shim_slider_get_value qt-handle))

    ; ---- platform interface ----

    (define/public (set-border on?)   (void))
    (define/public (direct-show on?)  (void))
    (define/override (is-shown?)        #t)
    (define/override (gets-focus?)      #t)
    (define/override (get-qt-handle)    qt-handle)
    (define/public   (command e)        (callback this e))
    (define/override (get-top-frame)
      (let loop ([p the-parent])
        (if (and p (object? p) (is-a? p window%))
            (let ([pp (send p get-parent)])
              (if pp (loop pp) p))
            #f)))))
