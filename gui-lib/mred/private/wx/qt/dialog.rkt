#lang racket/base
; Qt dialog% — applies dialog-mixin to frame%.
; Modal behavior: Racket yields on a semaphore until the dialog is hidden.
; No QDialog::exec(), no nested QEventLoop — the pump invariant is preserved.
(require racket/class
         "../common/dialog.rkt"
         "../common/queue.rkt"
         "frame.rkt")

(provide dialog%)

(define dialog%
  (class (dialog-mixin frame%)
    (init parent label x y w h [style null])
    (inherit get-eventspace)
    (super-new [parent parent] [label label] [x x] [y y] [w w] [h h] [style style])

    ; Toggles the toolkit-level parent-disable (frame%'s modal-enable) on
    ; every top-level window in the eventspace, mirroring wx/win32/dialog.rkt
    ; (docs/HACKING.md §18.3). `this` is passed as the ignore-win so the
    ; dialog being closed doesn't count itself as "other" while its own
    ; dialog-level is still set.
    (define/override (direct-show on?)
      (when on? (super direct-show on?))
      (for ([f (in-list (get-top-level-windows (get-eventspace)))])
        (send f modal-enable (and (not on?) this)))
      (unless on? (super direct-show on?)))))
