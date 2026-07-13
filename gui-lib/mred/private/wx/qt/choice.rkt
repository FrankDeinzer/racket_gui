#lang racket/base
; Qt choice% — wraps a QComboBox via the shim.
; Init args mirror wx/win32 + wx/gtk's choice%, as received from
; wxlitem.rkt's wx-internal-choice% after make-simple-control% consumes
; window-style: parent cb label x y w h choices style font.
(require racket/class
         "../common/event.rkt"
         "../common/queue.rkt"
         "window.rkt"
         "utils.rkt")

(provide choice%)

(define choice%
  (class window%
    (init parent cb label x y w h choices style font)

    (define the-eventspace (current-eventspace))
    (define the-parent parent)
    (define callback cb)
    (define count (length choices))

    ; changed-fn captures `this`; runs later in atomic + queued context.
    (define changed-fn
      (lambda (ud)
        (queue-event the-eventspace
                     (lambda ()
                       (callback this
                                 (make-object control-event% 'choice))))))

    (define parent-handle
      (if (and parent (object? parent) (is-a? parent window%))
          (send parent get-content-hwnd)
          (error 'qt-choice% "parent must be a Qt window%; got ~a" parent)))

    (define qt-handle
      (shim_choice_create parent-handle changed-fn #f))

    (for ([s (in-list choices)]) (shim_choice_append qt-handle s))

    (super-new [handle     qt-handle]
               [parent     parent]
               [eventspace the-eventspace])
    ; After choices, not before: sizeHint() should reflect populated items.
    (send this seed-size-from-native-hint)

    ; ---- sizing ----

    (define/override (set-size x y nw nh)
      (super set-size x y nw nh)
      (when (and nw (> nw 0) nh (> nh 0))
        (shim_widget_set_geometry qt-handle
                                  (if (and x (>= x 0)) x 0)
                                  (if (and y (>= y 0)) y 0)
                                  nw nh)))

    ; ---- choice% contract (mirrors wx/win32, wx/gtk) ----

    (define/public (set-selection i)
      (shim_choice_set_selection qt-handle i))

    (define/public (get-selection)
      (shim_choice_get_selection qt-handle))

    (define/public (number) count)

    (define/public (clear)
      (set! count 0)
      (shim_choice_clear qt-handle))

    ; Defined as append*/exposed as append (racket/class rename form), same
    ; convention wx/gtk's and wx/win32's choice% use.
    (public [append* append])
    (define (append* s)
      (set! count (add1 count))
      (shim_choice_append qt-handle s))

    (define/public (delete i)
      (set! count (sub1 count))
      (shim_choice_delete qt-handle i))

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
