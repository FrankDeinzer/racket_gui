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

; Proactive on-demand refresh interval, in pump ticks (50ms each) -- see
; `refresh-on-demand-menus!` below.
(define on-demand-refresh-every-ticks 40) ; ~2s

; win32 hooks WM_INITMENU, gtk hooks the top-level GtkMenuItem's "select"
; signal, cocoa uses a queue-suspend gate (queue.rkt) -- all three run the
; demand-callback cascade (menu-bar%'s on-demand, which recurses into every
; submenu, e.g. framework's "Open Recent") *synchronously*, blocking the
; native menu-open call until it's done, so the user never sees a stale
; submenu. Rule 2 forbids that here (Qt callbacks may only post, never call
; back into Racket synchronously) -- wx/qt/menu.rkt's about-to-show-cb only
; queues the cascade, so QMenu::aboutToShow can return (and Qt/Cocoa can
; sync+show the native menu) before the queued rebuild has actually run.
; Measured (2026-09-26, single verified DrRacket process, no stale process
; contamination): opening "File" then immediately opening its "Open Recent"
; submenu shows it empty on a completely fresh window (menu clicked <1s
; after the window first appears) -- so the rebuild itself isn't broken, it
; just hasn't run yet by the time Qt displays the submenu (framework/
; private/handler.rkt's own `install-recent-items` comment: "we run out of
; time during the callback and things go awry", hence its own do-it-twice
; workaround -- this is a known cross-backend timing concern, not new here).
; Since the queued cascade can't be made synchronous without breaking Rule
; 2, close the race from the other end: run the exact same (already Rule-2-
; safe, already-idempotent) cascade proactively on a timer, for every live
; top-level frame, so the data is normally already fresh by the time a user
; gets around to opening a menu -- the reactive aboutToShow path above still
; runs too (redundant, harmless) for the rare frame opened seconds ago.
; Verified fixed (2026-09-26, 2/2 trials, single-process-hygiene confirmed
; via `ps` before and after each launch): clicking File then immediately
; Open Recent within ~400ms of the window first appearing already shows the
; full, correctly populated list. Overhead: idle CPU time over a 15s window
; with the timer enabled vs. disabled (interval set to a huge number) was
; 0.91s vs. 0.76s -- about 1 percentage point of average CPU, negligible;
; `do-install-recent-items`'s own `menu-items-still-same?` check makes an
; unchanged rebuild cheap (string comparison only, no filesystem I/O), so
; most ticks do effectively nothing.
(define (refresh-on-demand-menus!)
  (queue-event (current-eventspace)
    (lambda ()
      (for ([f (in-list (get-top-level-windows))])
        (send f on-menu-click)))))

(define (qt-start-event-pump)
  (unless pump-started?
    (set! pump-started? #t)
    (thread
     (lambda ()
       (let loop ([tick 0])
         ; Poll every 50 ms.  A proper wakeup mechanism is a
         ; follow-up task (see ARCHITECTURE.md §8).
         (sync/timeout 0.05 never-evt)
         ; 0ms: draining without waiting avoids CFRunLoopRunInMode holding the
         ; atomic lock and conflicting with Racket CS's mach-port sleep on macOS.
         (atomically (shim_pump 0))
         (when (zero? (modulo tick on-demand-refresh-every-ticks))
           (refresh-on-demand-menus!))
         (loop (add1 tick)))))))
