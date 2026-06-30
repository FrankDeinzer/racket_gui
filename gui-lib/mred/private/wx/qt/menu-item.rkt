#lang racket/base
; Qt platform menu-item%.
; Not a Qt widget — it's a Racket identity token passed back through
; enable/delete/check/set-label as the key for looking up the QAction*.
(require racket/class
         "window.rkt")

(provide menu-item%)

(define menu-item%
  (class window%
    (init-rest _args)
    (super-new [handle #f] [parent #f])
    ; Returns this object as the opaque id used in menu%'s item-table.
    (define/public (id) this)))
