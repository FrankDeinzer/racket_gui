#lang racket/base
; Qt gauge% -- wraps a QProgressBar via the shim.
; Init signature matches win32/gtk's wx:gauge% (wxlitem.rkt's
; wx-internal-gauge% after make-control% strips mred/proxy/style):
;   parent label rng x y w h style font
; Purely visual/non-interactive -- no callback, no text overlay (wx gauge%
; never shows a percentage label, unlike QProgressBar's default).
(require racket/class
         "../common/queue.rkt"
         "window.rkt"
         "utils.rkt")

(provide gauge%)

(define gauge%
  (class window%
    (init parent label rng x y w h style font)

    (define qt-handle
      (if (and parent (object? parent) (is-a? parent window%))
          (shim_gauge_create (send parent get-content-hwnd)
                             (if (memq 'vertical style) 1 0)
                             rng 0)
          #f))

    (super-new [handle     qt-handle]
               [parent     parent]
               [eventspace (current-eventspace)]
               [no-show?   (and (memq 'deleted style) #t)])
    (when qt-handle (send this seed-size-from-native-hint))

    (define/override (set-size nx ny nw nh)
      (super set-size nx ny nw nh)
      (when qt-handle
        (shim_widget_set_geometry qt-handle
                                  (if (and nx (>= nx 0)) nx 0)
                                  (if (and ny (>= ny 0)) ny 0)
                                  (max (or nw 1) 1)
                                  (max (or nh 1) 1))))

    ; ---- value protocol (gauge% contract, mirrors win32/gtk) ----

    (define/public (set-range r) (when qt-handle (shim_gauge_set_range qt-handle r)))
    (define/public (get-range)   (if qt-handle (shim_gauge_get_range qt-handle) 0))
    (define/public (set-value v) (when qt-handle (shim_gauge_set_value qt-handle v)))
    (define/public (get-value)   (if qt-handle (shim_gauge_get_value qt-handle) 0))

    ; ---- platform interface ----

    (define/public (set-border on?)  (void))
    (define/public (direct-show on?) (void))
    (define/override (gets-focus?)     #f)))
