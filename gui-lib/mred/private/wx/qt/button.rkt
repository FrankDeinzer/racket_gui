#lang racket/base
; Qt button% — wraps a QPushButton via the shim.
(require racket/class
         "../common/event.rkt"
         "../common/queue.rkt"
         "window.rkt"
         "utils.rkt")

(provide button%)

(define button%
  (class window%
    ; Init args as received from wxitem.rkt after make-item% consumes
    ; window-style:
    ;   parent  cb  label  x  y  w  h  style  font
    (init parent cb label x y w h style font)

    (define the-eventspace (current-eventspace))
    (define the-parent parent)
    (define callback cb)

    ; click-fn captures `this`; runs later in atomic + queued context.
    (define click-fn
      (lambda (ud)
        (queue-event the-eventspace
                     (lambda ()
                       (callback this
                                 (make-object control-event% 'button))))))

    (define parent-handle
      (if (and parent (object? parent) (is-a? parent window%))
          (send parent get-content-hwnd)
          (error 'qt-button% "parent must be a Qt window%; got ~a" parent)))

    (define qt-handle
      (shim_button_create parent-handle
                          (if (string? label) label "Button")
                          click-fn
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

    ; ---- platform interface ----

    (define/public (set-label lbl)
      (when (string? lbl)
        (void)))  ; Qt label change not exposed in shim yet; spike only

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
