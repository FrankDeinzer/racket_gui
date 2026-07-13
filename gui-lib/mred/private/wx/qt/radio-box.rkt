#lang racket/base
; Qt radio-box% — wraps a QButtonGroup of QRadioButtons via the shim.
; Init args mirror wx/win32 + wx/gtk's radio-box%, as received from
; wxlitem.rkt's wx-internal-radio-box% after make-simple-control% consumes
; window-style: parent cb label x y w h labels val style font.
(require racket/class
         "../common/event.rkt"
         "../common/queue.rkt"
         "window.rkt"
         "utils.rkt")

(provide radio-box%)

(define radio-box%
  (class window%
    (init parent cb label x y w h labels val style font)

    (define the-eventspace (current-eventspace))
    (define the-parent parent)
    (define callback cb)
    (define count (length labels))

    ; clicked-fn captures `this`; runs later in atomic + queued context.
    (define clicked-fn
      (lambda (ud)
        (queue-event the-eventspace
                     (lambda ()
                       (callback this
                                 (make-object control-event% 'radio-box))))))

    (define parent-handle
      (if (and parent (object? parent) (is-a? parent window%))
          (send parent get-content-hwnd)
          (error 'qt-radio-box% "parent must be a Qt window%; got ~a" parent)))

    (define qt-handle
      (shim_radio_box_create parent-handle
                             (if (memq 'horizontal style) 1 0)
                             clicked-fn
                             #f))

    (for ([l (in-list labels)])
      (shim_radio_box_append_button qt-handle (if (string? l) l "")))

    (unless (= val -1)
      (shim_radio_box_set_selection qt-handle val))

    (super-new [handle     qt-handle]
               [parent     parent]
               [eventspace the-eventspace])
    ; After buttons, not before: sizeHint() should reflect the built layout.
    (send this seed-size-from-native-hint)

    ; ---- sizing ----

    (define/override (set-size x y nw nh)
      (super set-size x y nw nh)
      (when (and nw (> nw 0) nh (> nh 0))
        (shim_widget_set_geometry qt-handle
                                  (if (and x (>= x 0)) x 0)
                                  (if (and y (>= y 0)) y 0)
                                  nw nh)))

    ; ---- radio-box% contract (mirrors wx/win32, wx/gtk) ----

    (define/public (set-selection i)
      (shim_radio_box_set_selection qt-handle i))

    (define/public (get-selection)
      (shim_radio_box_get_selection qt-handle))

    (define/public (number) count)

    (define/public (enable-button i on?)
      (shim_radio_box_enable_button qt-handle i (if on? 1 0)))

    (define/public (button-focus i)
      (shim_radio_box_button_focus qt-handle i))

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
