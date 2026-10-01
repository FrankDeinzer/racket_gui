#lang racket/base
; Qt button% — wraps a QPushButton via the shim.
(require racket/class
         racket/draw
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

    ; label: string | bitmap% | (list bitmap% string pos)  (wie gtk/button.rkt)
    (define (label-text l)
      (cond [(string? l) l] [(pair? l) (cadr l)] [(is-a? l bitmap%) ""] [else "Button"]))
    (define (label-bitmap l)
      (cond [(pair? l) (car l)] [(is-a? l bitmap%) l] [else #f]))
    ; Bitmap als Icon (straight-alpha ARGB); Rueckgabe #f = Shim ohne shim_button_set_icon.
    (define (apply-icon! h l)
      (define bm (label-bitmap l))
      (and bm
           (let* ([w (send bm get-width)] [h* (send bm get-height)]
                  [buf (make-bytes (* w h* 4) 0)])
             (send bm get-argb-pixels 0 0 w h* buf)
             (let ([mask (send bm get-loaded-mask)])
               (when mask (send mask get-argb-pixels 0 0 w h* buf #t)))
             (positive? (shim_button_set_icon h buf w h*
                                              (if (and (pair? l) (pair? (cddr l)) (eq? (caddr l) 'right)) 1 0))))))

    (define qt-handle
      (shim_button_create parent-handle
                          (label-text label)
                          click-fn
                          #f))
    (let ([bm (label-bitmap label)])
      (when (and bm (not (apply-icon! qt-handle label)) (not (pair? label)))
        (shim_button_set_label qt-handle "Button")))

    (super-new [handle     qt-handle]
               [parent     parent]
               [eventspace the-eventspace]
               [no-show?   (and (memq 'deleted style) #t)])
    (send this seed-size-from-native-hint)
    (send this qt-forward-nav-keys!)

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
      (cond
        [(string? lbl) (shim_button_set_label qt-handle lbl)]
        [(label-bitmap lbl) (apply-icon! qt-handle lbl)]))

    (define/public (set-border on?)   (void))
    (define/public (direct-show on?)  (void))
    (define/override (gets-focus?)      #t)
    (define/override (get-qt-handle)    qt-handle)
    (define/public   (command e)        (callback this e))
    (define/override (get-top-frame)
      (let loop ([p the-parent])
        (if (and p (object? p) (is-a? p window%))
            (let ([pp (send p get-parent)])
              (if pp (loop pp) p))
            #f)))))
