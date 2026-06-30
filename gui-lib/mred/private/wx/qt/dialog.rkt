#lang racket/base
; Qt dialog% — applies dialog-mixin to frame%.
; Modal behavior: Racket yields on a semaphore until the dialog is hidden.
; No QDialog::exec(), no nested QEventLoop — the pump invariant is preserved.
(require racket/class
         "../common/dialog.rkt"
         "frame.rkt")

(provide dialog%)

(define dialog%
  (class (dialog-mixin frame%)
    (init parent label x y w h [style null])
    (super-new [parent parent] [label label] [x x] [y y] [w w] [h h] [style style])))
