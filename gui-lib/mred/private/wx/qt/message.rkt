#lang racket/base
; Qt platform message% — wraps a QLabel for static text display.
; Init signature matches what wx-message% (wxitem.rkt) passes after the
; make-glue%/make-item%/wx-make-window% layer strips mred/proxy/style:
;   parent label x y style font [color #f]
(require racket/class
         "../common/queue.rkt"
         "window.rkt"
         "utils.rkt")

(provide message%)

(define message%
  (class window%
    (init parent label x y style font [color #f])
    (define current-label (if (string? label) label ""))
    (define qt-handle
      (if (and parent (object? parent) (is-a? parent window%))
          (shim_label_create (send parent get-content-hwnd) current-label)
          #f))

    (super-new [handle qt-handle]
               [parent parent]
               [eventspace (current-eventspace)])
    (send this seed-size-from-native-hint)

    (define/override (set-size nx ny nw nh)
      (super set-size nx ny nw nh)
      (when qt-handle
        (shim_widget_set_geometry qt-handle
                                  (if (and nx (>= nx 0)) nx 0)
                                  (if (and ny (>= ny 0)) ny 0)
                                  (max (or nw 1) 1)
                                  (max (or nh 1) 1))))

    (define/public (set-label lbl)
      (when (string? lbl)
        (set! current-label lbl)
        (when qt-handle (shim_label_set_text qt-handle lbl))))

    (define/public  (get-label)          current-label)
    (define/override (get-qt-handle)     qt-handle)
    (define/override (get-content-hwnd)  qt-handle)
    (define/public  (command e)          (void))
    (define/public  (set-color c)        (void))
    (define/public  (get-color)          #f)
    (define/public  (set-preferred-size) #f)
    (define/override (is-shown?)         #t)))
