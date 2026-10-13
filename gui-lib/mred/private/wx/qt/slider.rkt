#lang racket/base
; Qt slider% — wraps a QSlider via the shim.
; Init args mirror wx/win32 + wx/gtk's slider%, as received from
; wxlitem.rkt's wx-internal-slider% after make-control% consumes
; window-style: parent cb label val lo hi x y w style font.
;
; QSlider has no built-in numeric readout (unlike gtk's
; gtk_scale_set_draw_value or win32's separate STATIC control) --
; docs/HACKING.md §21.6. Mirrors win32's approach: when not 'plain,
; wrap the slider and a value label in a shim_panel_create container
; and position both by hand in set-size; 'plain keeps the old
; bare-slider behavior.
(require racket/class
         "../common/event.rkt"
         "../common/queue.rkt"
         "window.rkt"
         "utils.rkt")

(provide slider%)

(define THICKNESS 24)
(define MIN_LENGTH 80)

(define slider%
  (class item%
    (init parent cb label val lo hi x y w style font)

    (define the-eventspace (current-eventspace))
    (define the-parent parent)
    (define callback cb)
    (define vertical? (or (memq 'vertical style) (memq 'upward style)))
    (define plain? (and (memq 'plain style) #t))

    (define parent-handle
      (if (and parent (object? parent) (is-a? parent window%))
          (send parent get-content-hwnd)
          (error 'qt-slider% "parent must be a Qt window%; got ~a" parent)))

    ; changed-fn captures `this`; runs later in atomic + queued context.
    ; Label text update happens in the queued thunk (eventspace thread),
    ; not synchronously in this native callback (Regel 2).
    (define changed-fn
      (lambda (ud)
        (queue-event the-eventspace
                     (lambda ()
                       (when value-handle
                         (shim_label_set_text value-handle (format "~a" (get-value)))
                         (place-value!))
                       (callback this
                                 (make-object control-event% 'slider))))))

    (define panel-handle (and (not plain?) (shim_panel_create parent-handle 0)))

    (define slider-handle
      (shim_slider_create (or panel-handle parent-handle)
                          (if vertical? 1 0)
                          lo hi val
                          changed-fn
                          #f))

    (define value-handle
      (and panel-handle (shim_label_create panel-handle (format "~a" val))))

    (define-values (value-w value-h)
      (if value-handle
          (let ([widest (if (>= (string-length (format "~a" lo)) (string-length (format "~a" hi)))
                             (format "~a" lo)
                             (format "~a" hi))])
            (shim_label_set_text value-handle widest)
            (define-values (hint-w hint-h) (shim_widget_get_size_hint value-handle))
            (shim_label_set_text value-handle (format "~a" val))
            (values (max hint-w 1) (max hint-h 1)))
          (values 0 0)))

    (define qt-handle (or panel-handle slider-handle))
    (define last-nw 0)
    (define value-y 0)
    (define KNOB 18)
    (define min-v lo)
    (define max-v hi)

    (super-new [handle     qt-handle]
               [parent     parent]
               [eventspace the-eventspace]
               [no-show?   (and (memq 'deleted style) #t)])
    (if panel-handle
        (if vertical?
            (send this set-size #f #f (+ THICKNESS value-w) (max value-h MIN_LENGTH))
            (send this set-size #f #f (max value-w MIN_LENGTH) (+ THICKNESS value-h)))
        (send this seed-size-from-native-hint))
    (send this qt-forward-nav-keys!)

    ; ---- sizing ----

    (define/override (set-size x y nw nh)
      (super set-size x y nw nh)
      (when (and nw (> nw 0) nh (> nh 0))
        (shim_widget_set_geometry qt-handle
                                  (if (and x (>= x 0)) x 0)
                                  (if (and y (>= y 0)) y 0)
                                  nw nh)
        (set! last-nw nw)
        (cond
          ; 'plain: qt-handle IS the slider (already placed above).  Re-placing it at
          ; (0,0) here (the old code) pinned it to the parent's origin and drew it over
          ; the item label (visual matrix, scene "slider", §84).
          [(not panel-handle) (void)]
          [vertical?
           (define dx (quotient (max 0 (- nw THICKNESS value-w)) 2))
           (shim_widget_set_geometry slider-handle dx 0 THICKNESS nh)
           (shim_widget_set_geometry value-handle (+ dx THICKNESS)
                                     (quotient (max 0 (- nh value-h)) 2)
                                     value-w value-h)]
          [else
           ; gtk draws the value above the slider, following the knob
           ; (gtk_scale_set_draw_value, value position top) -- not below it.
           (define dy (quotient (max 0 (- nh THICKNESS value-h)) 2))
           (set! value-y dy)
           (shim_widget_set_geometry slider-handle 0 (+ dy value-h) nw THICKNESS)
           (place-value!)])))

    ; Horizontal slider: center the value label over the knob.
    (define/private (place-value!)
      (when (and value-handle (not vertical?) (> last-nw 0))
        (define span (max 1 (- max-v min-v)))
        (define frac (/ (- (max min-v (min max-v (get-value))) min-v) span))
        (define cx (+ (quotient KNOB 2) (* frac (max 0 (- last-nw KNOB)))))
        (define x (max 0 (min (max 0 (- last-nw value-w)) (inexact->exact (round (- cx (/ value-w 2.0)))))))
        (shim_widget_set_geometry value-handle x value-y value-w value-h)))

    ; ---- value protocol (slider% contract, mirrors gtk/win32) ----

    (define/public (set-value v)
      (shim_slider_set_value slider-handle v)
      (when value-handle
        (shim_label_set_text value-handle (format "~a" v))
        (place-value!)))

    (define/public (get-value)
      (shim_slider_get_value slider-handle))

    ; ---- platform interface ----

    (define/public (set-border on?)   (void))
    (define/public (direct-show on?)  (void))
    (define/override (gets-focus?)      #t)
    (define/override (get-qt-handle)    qt-handle)
    (define/public   (command e)        (callback this e))
    (define/override (get-top-frame)
      (let loop ([p the-parent])
        (if (and p (object? p) (is-a? p window%))
            (let ([pp (and (not (send p top-level-window?)) (send p get-parent))])
              (if pp (loop pp) p))
            #f)))))
