#lang racket/base
; Qt check-box% — wraps a QCheckBox via the shim.
; Init args mirror button%'s, as received from wxitem.rkt's wx-check-box%
; after make-item% consumes window-style: parent cb label x y w h style font.
(require racket/class
         "../common/event.rkt"
         "../common/queue.rkt"
         "window.rkt"
         "utils.rkt")

(provide check-box%)

(define check-box%
  (class window%
    (init parent cb label x y w h style font)

    (define the-eventspace (current-eventspace))
    (define the-parent parent)
    (define callback cb)

    ; toggle-fn captures `this`; runs later in atomic + queued context.
    (define toggle-fn
      (lambda (ud)
        (queue-event the-eventspace
                     (lambda ()
                       (callback this
                                 (make-object control-event% 'check-box))))))

    (define parent-handle
      (if (and parent (object? parent) (is-a? parent window%))
          (send parent get-content-hwnd)
          (error 'qt-check-box% "parent must be a Qt window%; got ~a" parent)))

    (define qt-handle
      (shim_check_box_create parent-handle
                             (if (string? label) label "")
                             toggle-fn
                             #f))

    (super-new [handle     qt-handle]
               [parent     parent]
               [eventspace the-eventspace])

    ; ---- sizing ----

    (define/override (set-size x y nw nh)
      (super set-size x y nw nh)
      (when (and nw (> nw 0) nh (> nh 0))
        (shim_widget_set_geometry qt-handle
                                  (if (and x (>= x 0)) x 0)
                                  (if (and y (>= y 0)) y 0)
                                  nw nh)))

    ; ---- value protocol (check-box% contract, mirrors gtk/win32) ----

    (define/public (set-value v)
      (shim_check_box_set_checked qt-handle (if v 1 0)))

    (define/public (get-value)
      (not (zero? (shim_check_box_get_checked qt-handle))))

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
