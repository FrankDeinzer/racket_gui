#lang racket/base
; Qt platform menu-bar%.
; Wraps a QMenuBar. Attaches to a QMainWindow via frame's set-menu-bar.
; Also provides the top-frame reference for menu% action callbacks.
(require racket/class
         "window.rkt"
         "menu.rkt"
         "utils.rkt")

(provide menu-bar%
         debug-get-appended-menu)

; Register the is-a? predicate so menu.rkt can walk up to find the frame
; without a circular dependency.
(register-menu-bar-predicate! (lambda (x) (and x (is-a? x menu-bar%))))

; W3 measurement (2026-07-08_prompt-2): captures the wx-level menu% for each
; appended top-level bar title, keyed by title, so a debug script can call its
; existing `popup` method directly on the SAME QMenu instance embedded in the
; real QMenuBar — bypassing QMenuBar's click activation entirely. Gated behind
; PLT_QT_DEBUG; empty/unused otherwise. Measurement-only, not a platform API.
(define debug-appended-menus (make-hash))
(define (debug-get-appended-menu title) (hash-ref debug-appended-menus title #f))

(define menu-bar%
  (class window%
    (init-rest _args)
    (super-new [handle #f] [parent #f])

    ; ---- Qt handle ----------------------------------------------------------
    (define qt-menubar (shim_menubar_create))

    (define/public (get-menubar-handle) qt-menubar)

    ; ---- top-frame reference ------------------------------------------------
    ; Set by the platform frame's set-menu-bar once the bar is attached.
    (define top-frame #f)
    (define/public (set-frame fr) (set! top-frame fr))
    (define/public (get-top-window) top-frame)

    ; ---- append -------------------------------------------------------------
    ; menu: platform menu% (or glue extending it)
    ; title: display string (already stripped of tab accelerator chars by glue)
    (define/public (append menu title)
      ; Tell the menu who its parent is so action callbacks can find the frame.
      (send menu set-parent this)
      ; QMenuBar::addMenu derives the bar item's text from the menu's title;
      ; a top-level menu% is created with an empty title (its label arrives here
      ; as `title`, not as popup-label), so set it now or the bar item is
      ; zero-width and the whole bar collapses to height 0.
      (shim_menu_set_title (send menu get-qt-menu) title)
      (shim_menubar_add_menu qt-menubar (send menu get-qt-menu))
      (when (getenv "PLT_QT_DEBUG")
        (hash-set! debug-appended-menus title menu)))

    ; ---- enable-top ---------------------------------------------------------
    (define/public (enable-top pos on?)
      (shim_menubar_enable_at qt-menubar pos (if on? 1 0)))

    ; ---- delete -------------------------------------------------------------
    ; item: ignored (glue passes #f); pos: 0-based position
    (define/public (delete item pos)
      (shim_menubar_remove_at qt-menubar pos))))
