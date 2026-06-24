#lang racket/base
; Minimal Qt panel% — a logical grouping widget that forwards to its parent's
; Qt handle. The spike uses a flat VBoxLayout in the QMainWindow so panels
; need no independent Qt widget; they just delegate to parent.
(require racket/class
         "../common/queue.rkt"
         "window.rkt")

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

    ; Reuse parent's Qt handle — panels are logical in the spike.
    (define qt-handle
      (if (and parent (object? parent) (is-a? parent window%))
          (send parent get-qt-handle)
          #f))

    (super-new [handle     qt-handle]
               [parent     parent]
               [eventspace (current-eventspace)])

    (define/override (get-qt-handle)  qt-handle)
    (define/public   (get-content-hwnd) qt-handle)
    (define/public   (direct-show on?) (void))
    (define/override (is-shown?)     #t)))
