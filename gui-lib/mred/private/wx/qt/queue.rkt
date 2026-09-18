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
  (set-queue-wakeup! (lambda (fds) (atomically (shim_pump 0))))
  ; `(exit)` calls the C library's exit(), which runs QtCore/QtGui's own
  ; static-destructor chain via __cxa_finalize_ranges -- but nothing ever
  ; destroyed the QApplication first (shim_app_quit existed but had no
  ; caller). Without an orderly QApplication teardown, that static
  ; destruction order was never exercised/intended by Qt and crashes with
  ; a garbage `this` inside a QtGui virtual call once any lazily-loaded
  ; Qt subsystem (observed with the print-support platform plugin, only
  ; loaded on the first QPrintDialog/QPageSetupDialog) has registered its
  ; own globals -- macOS-observed, docs/HACKING.md §49.4/§50. A plumber
  ; flush runs synchronously inside `exit`, on the same thread, before the
  ; process actually terminates -- exactly the hook needed to give
  ; QApplication's destructor a chance to run first.
  (plumber-add-flush! (current-plumber) (lambda (handle) (shim_app_quit))))

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
