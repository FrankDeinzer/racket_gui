#lang racket/base
; Qt panel% — a real QWidget container.
; Children (canvas, button, nested panels) parent themselves to this widget.
; Racket drives all geometry via shim_widget_set_geometry.
(require racket/class
         "../common/queue.rkt"
         "window.rkt"
         "utils.rkt")

(provide panel%
         panel-mixin)

(define (panel-mixin %)
  (class %
    (inherit get-parent)
    (super-new)
    (define/public   (adopt-child child)       (void))
    (define/public   (get-label-position)      'horizontal)
    (define/public   (set-label-position pos)  (void))
    (define/public   (set-item-cursor x y)     (void))
    (define/override (register-child child on?) (void))))

(define panel%
  (class (panel-mixin window%)
    (init parent
          x y w h
          style
          [label #f])

    (define the-parent parent)

    (define qt-handle
      (if (and parent (object? parent) (is-a? parent window%))
          (shim_panel_create (send parent get-content-hwnd))
          #f))

    (super-new [handle     qt-handle]
               [parent     parent]
               [eventspace (current-eventspace)])

    ; ---- sizing ----

    (define/override (set-size x y nw nh)
      (super set-size x y nw nh)
      (when (and qt-handle nw (> nw 0) nh (> nh 0))
        (shim_widget_set_geometry qt-handle
                                  (if (and x (>= x 0)) x 0)
                                  (if (and y (>= y 0)) y 0)
                                  nw nh)))

    (define/override (get-qt-handle)    qt-handle)
    ; Children of this panel parent to this widget.
    (define/override (get-content-hwnd) qt-handle)
    (define/public   (direct-show on?)  (void))
    (define/override (is-shown?)        #t)))
