#lang racket/base
; Qt event pump.
; Racket drives the loop; Qt is pumped periodically via shim_pump().
(require racket/class
         "../../lock.rkt"
         "../common/queue.rkt"
         "utils.rkt")

(provide qt-init!
         qt-start-event-pump)

(define pump-started? #f)

(define (qt-init!)
  (shim_app_init)
  ; Hook Racket's scheduler: report Qt events as "pending" so the
  ; scheduler keeps yielding instead of sleeping indefinitely.
  (set-check-queue! (lambda () (not (zero? (shim_events_pending)))))
  ; Wakeup hook: on Windows the scheduler calls this when it would
  ; block; pumping 0 ms processes any immediately-ready events.
  (set-queue-wakeup! (lambda (fds) (atomically (shim_pump 0)))))

(define (qt-start-event-pump)
  (unless pump-started?
    (set! pump-started? #t)
    (thread
     (lambda ()
       (let loop ()
         ; Poll every 50 ms.  A proper wakeup mechanism is a
         ; follow-up task (see ARCHITECTURE.md §8).
         (sync/timeout 0.05 never-evt)
         ; 0ms: draining without waiting avoids CFRunLoopRunInMode holding the
         ; atomic lock and conflicting with Racket CS's mach-port sleep on macOS.
         (atomically (shim_pump 0))
         (loop))))))
