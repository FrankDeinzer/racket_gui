#lang racket/base
; Qt platform message% — wraps a QLabel for static text display.
; Init signature matches what wx-message% (wxitem.rkt) passes after the
; make-glue%/make-item%/wx-make-window% layer strips mred/proxy/style:
;   parent label x y style font [color #f]
(require racket/class
         racket/draw
         "../common/queue.rkt"
         "window.rkt"
         "utils.rkt")

(provide message%)

(define message%
  (class window%
    (init parent label x y style font [color #f])
    (define current-label (if (string? label) label ""))
    (define current-label-kind (if (string? label) label #f))
    (define qt-handle
      (if (and parent (object? parent) (is-a? parent window%))
          (shim_label_create (send parent get-content-hwnd) current-label)
          #f))
    ; Symbol-/Bitmap-Label (Dialog-Icons wie "caution" in Rueckfragen): wie gtk/message.rkt
    (define (apply-image-label! l)
      (when qt-handle
        (cond
          [(symbol? l)
           (shim_label_set_standard_icon qt-handle (case l [(caution) 1] [(stop) 2] [else 0]))]
          [(is-a? l bitmap%)
           (let* ([w (send l get-width)] [h (send l get-height)] [buf (make-bytes (* w h 4) 0)])
             (send l get-argb-pixels 0 0 w h buf)
             (let ([mask (send l get-loaded-mask)])
               (when mask (send mask get-argb-pixels 0 0 w h buf #t)))
             (shim_label_set_pixmap qt-handle buf w h))])))
    (unless (or (string? label) (not label)) (apply-image-label! label))

    (super-new [handle qt-handle]
               [parent parent]
               [eventspace (current-eventspace)]
               [no-show?   (and (memq 'deleted style) #t)])
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
      (cond
        [(string? lbl)
         (set! current-label lbl)
         (when qt-handle (shim_label_set_text qt-handle lbl))]
        [(or (symbol? lbl) (is-a? lbl bitmap%)) (apply-image-label! lbl)]))

    (define/public  (get-label)          current-label)
    (define/override (get-qt-handle)     qt-handle)
    (define/override (get-content-hwnd)  qt-handle)
    (define/public  (command e)          (void))
    ; Wie gtk/message.rkt: nur bei Text-Label wirksam; #f stellt die Standardfarbe wieder her.
    (define color-val color)
    (define (apply-color! c)
      (when qt-handle
        (if c
            (shim_label_set_color qt-handle 1 (send c red) (send c green) (send c blue)
                                  (inexact->exact (round (* 255 (send c alpha)))))
            (shim_label_set_color qt-handle 0 0 0 0 255))))
    (when (and color-val (string? label)) (apply-color! color-val))
    (define/public  (get-color)          color-val)
    (define/public  (set-color c)
      (when (string? current-label-kind)
        (set! color-val c)
        (apply-color! c)
        (void)))
    (define/public  (set-preferred-size) #f)))
