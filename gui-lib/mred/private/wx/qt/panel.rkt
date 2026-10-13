#lang racket/base
; Qt panel% — a real QWidget (QFrame) container.
; Children (canvas, button, nested panels) parent themselves to this widget.
; Racket drives all geometry via shim_widget_set_geometry.
; 'border in style draws a frame rectangle (mirrors win32's WS_BORDER /
; gtk's 'border check) -- docs/HACKING.md §21.6.
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
    ; Label position: plain state read by wxlitem.rkt/wxtextfield.rkt (is-horiz?, gauge/slider
    ; sizing), like gtk/win32/cocoa (HACKING §75.1).
    (define lbl-pos 'horizontal)
    (define children null)
    (define/public   (adopt-child child)       (send child set-parent this))
    (define/public   (get-label-position)      lbl-pos)
    (define/public   (set-label-position pos)  (set! lbl-pos pos))
    (define/public   (set-item-cursor x y)     (void))
    ; Children registry (gtk/panel.rkt): shown children register via window%'s `show`, so
    ; (send a-panel refresh) cascades to every shown child (canvas% repaints on its own refresh).
    (define/override (register-child child on?)
      (let ([now-on? (and (memq child children) #t)])
        (unless (eq? on? now-on?)
          (set! children (if on? (cons child children) (remq child children))))))
    (define/override (refresh-all-children)
      (for ([child (in-list children)])
        (send child refresh)))))

(define panel%
  (class (panel-mixin window%)
    (init parent
          x y w h
          style
          [label #f])

    (define the-parent parent)

    (define qt-handle
      (if (and parent (object? parent) (is-a? parent window%))
          (shim_panel_create (send parent get-content-hwnd)
                             (if (memq 'border style) 1 0))
          #f))

    (super-new [handle     qt-handle]
               [parent     parent]
               [eventspace (current-eventspace)]
               [no-show?   (and (memq 'deleted style) #t)])

    ; ---- sizing ----

    (define/override (set-size x y nw nh)
      (super set-size x y nw nh)
      ; Zero sizes are applied too (only the width/height bookkeeping in
      ; window% ignores them): a panel that shrinks to 0 must not keep its old
      ; geometry and keep swallowing clicks over its neighbours.
      (when (and qt-handle nw nh (>= nw 0) (>= nh 0))
        (shim_widget_set_geometry qt-handle
                                  (if (and x (>= x 0)) x 0)
                                  (if (and y (>= y 0)) y 0)
                                  nw nh)))

    (define/override (get-qt-handle)    qt-handle)
    ; Children of this panel parent to this widget.
    (define/override (get-content-hwnd) qt-handle)
    (define/public   (direct-show on?)  (void))))
