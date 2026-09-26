#lang racket/base
; Qt platform menu%.
; Wraps a QMenu handle. Actions are tracked in item-table (id → QAction*) and
; items-in-order ((id . QAction*) ...) for positional delete.
; Separator items have id = #f in the order list.
; Callback discipline: every action callback is _callback_t (#:atomic? #t)
; and only posts to the Racket eventspace — never blocks.
(require racket/class
         racket/list
         "../common/queue.rkt"
         "../common/event.rkt"
         "window.rkt"
         "utils.rkt")

(provide menu%
         register-menu-bar-predicate!)

; Capture racket/base's append before it is shadowed by define/public (append ...)
; inside the class body.
(define list-append append)

; A standalone popup-menu% (mrpopup.rkt) has no top-level-window parent to
; queue events through — window%'s `popup-menu` (window.rkt) calls
; `QMenu::popup()` (Rule 1: non-blocking, no exec()) and returns immediately,
; so nothing on the Racket side keeps the mred-level popup-menu%/menu%
; instance (and the `retained-callbacks` closures below) alive while the
; native QMenu is still on screen and waiting for a click. gtk's menu%
; (wx/gtk/menu.rkt `popup`) pins the same way via `global-prevent-gc`;
; win32 never needs this because `TrackPopupMenu` blocks. A single slot is
; enough here (not a set/hash): at most one popup-menu is ever genuinely
; open at a time, and overwriting the slot on the next `popup` call bounds
; a cancelled-and-abandoned popup's leak to one object instead of pinning
; it forever.
(define pinned-popup #f)

; mred/private/mrmenu.rkt's calc-labels appends a "\tCut=<mod-char><key-code>"
; suffix to every macOS menu-item label that has a keyboard shortcut -- a
; wxWidgets-era encoding meant *only* for wx/cocoa/menu-item.rkt's own parser
; (set-menu-item-shortcut there: regexp-matches the exact same pattern, turns
; it into an NSMenuItem keyEquivalent/modifierMask). Nothing else was ever
; meant to see this string. Passed through raw to shim_action_create/
; shim_action_set_label, it used to reach QAction::setText() verbatim --
; showing the garbled internal encoding (or an invisible replacement
; character) instead of a shortcut hint, and explaining both halves of the
; user-visible bug (docs/HACKING.md): no visible "⌘C" next to Copy, and (for
; the actual key-handling half) see shim_app_init's AA_MacDontSwapCtrlAndMeta
; fix, a separate root cause.
;
; This only rewrites the suffix into a human-readable "⌘C"-style hint for
; *display* -- it does not call QAction::setShortcut(), deliberately: this
; backend's real shortcut dispatch already goes entirely through Racket's own
; keymap chain (mred/private/wxtop.rkt's handle-menu-key), independent of any
; native/Qt-level accelerator. Wiring a second, native Qt shortcut on top
; would risk the same key press firing the callback twice (once via Qt's own
; QShortcutMap, once via the existing Racket dispatch) -- untested, unbounded
; downside for a purely cosmetic fix. A tab-suffixed label is exactly the
; same convention gtk/win32's own labels already use here (e.g. "\tCtrl+C"),
; which Qt's QMenu already renders as a right-aligned hint column without
; needing a real QKeySequence -- this just teaches it macOS's own symbols
; and modifier order (⌃⌥⇧⌘, per Apple's HIG) instead of leaking wx-cocoa's
; internal wire format.
(define (clean-macos-shortcut-label label)
  (define m (regexp-match #rx"^([^\t]*)\tCut=(.)(.*)$" label))
  (cond
    [(not m) label]
    [else
     (define plain (cadr m))
     (define flags (- (char->integer (string-ref (caddr m) 0)) (char->integer #\A)))
     (define key-code (string->number (cadddr m)))
     (cond
       [(not key-code) label] ; malformed suffix -- don't guess, leave as-is
       [else
        (define shift?  (positive? (bitwise-and flags 1)))
        (define option? (positive? (bitwise-and flags 2)))
        (define ctl?    (positive? (bitwise-and flags 4)))
        (define cmd?    (zero?     (bitwise-and flags 8))) ; bit 3 means "no cmd"
        (string-append plain "\t"
                        (if ctl? "⌃" "")
                        (if option? "⌥" "")
                        (if shift? "⇧" "")
                        (if cmd? "⌘" "")
                        (string (char-upcase (integer->char key-code))))])]))

; menu-bar% predicate — avoids circular require between menu.rkt and menu-bar.rkt.
; menu-bar.rkt registers itself at load time.
(define menu-bar-pred (lambda (x) #f))
(define (register-menu-bar-predicate! pred)
  (set! menu-bar-pred pred))

(define menu%
  (class window%
    ; popup-label: QMenu title, cosmetic only (top-level menu-bar menus get
    ; their title via shim_menu_set_title/shim_menu_add_submenu instead).
    ; popup-callback/font: see `popup`/`on-popup` below — the mrpopup.rkt
    ; fallback dispatch path for a standalone popup-menu%'s item clicks.
    (init [popup-label #f] [popup-callback #f] [font #f])
    (super-new [handle #f] [parent #f])

    ; init args aren't visible inside a method's own closures (only in the
    ; class body's immediate top level) -- rebind into a field so `append`'s
    ; leaf-item callback below can close over it.
    (define the-popup-callback popup-callback)

    ; ---- Qt handle ----------------------------------------------------------
    (define qt-menu (shim_menu_create (or popup-label "")))

    (define/public (get-qt-menu) qt-menu)

    ; ---- standalone-popup dispatch (mrpopup.rkt protocol) --------------------
    ; Set by `popup` below; consumed by the leaf-item callback in `append`
    ; when `find-top-frame` can't resolve a frame (i.e. this menu% was shown
    ; via window%'s `popup-menu`, not attached to a menu-bar). Mirrors gtk's
    ; `do-selected` fallback to `on-popup` (wx/gtk/menu.rkt).
    (define on-popup #f)

    ; ---- parent tracking ----------------------------------------------------
    (define the-parent #f)
    (define/public (set-parent p) (set! the-parent p))
    (define/public (get-parent-obj) the-parent)

    ; ---- about-to-show -> on-menu-click -> on-demand (docs/HACKING.md §37) --
    ; win32 hooks WM_INITMENU, gtk hooks the top-level GtkMenuItem's "select"
    ; signal -- both fire once, right before ANY menu (top-level or nested)
    ; becomes visible, and call the frame's on-menu-click, which cascades
    ; on-demand through the whole menu-bar tree (mrmenu.rkt's menu-bar%/menu%
    ; on-demand recurse into every item, including submenus) before the user
    ; sees stale enable/check state. Qt's equivalent per-menu signal is
    ; QMenu::aboutToShow. Retained as a field, same lifetime pattern as
    ; frame.rkt's resize-cb -- alive as long as this menu% object is.
    (define about-to-show-cb
      (lambda (_ud)
        (let ([frame (find-top-frame)])
          (when frame
            (queue-event (send frame get-eventspace)
              (lambda ()
                (send frame on-menu-click)))))))
    (shim_menu_set_about_to_show_cb qt-menu about-to-show-cb #f)

    ; ---- item tracking ------------------------------------------------------
    ; item-table: id → QAction* (leaf items only)
    (define item-table (make-hasheq))
    ; items-in-order: list of (id . QAction*) — id is #f for separators
    (define items-in-order '())
    ; retained-callbacks: id → cb closure, kept alive only so the GC never
    ; collects it while the native QAction* can still invoke it. `cb` in
    ; `append` is otherwise a plain local binding with no other Racket-side
    ; reference once `append` returns -- the same landmine filedialog.rkt's
    ; header comment documents (§19): a callback with nothing retaining it
    ; can be collected and leave the QAction holding a dead function pointer.
    ; Unlike button%/etc. (whose callback is a field of the widget itself),
    ; a menu% hosts many items, so each item's cb is retained here by id.
    (define retained-callbacks (make-hasheq))

    (define (order-push! id action)
      (set! items-in-order (list-append items-in-order (list (cons id action)))))
    (define (order-remove-at! pos)
      (define before (take items-in-order pos))
      (define after  (drop items-in-order (+ pos 1)))
      (set! items-in-order (list-append before after)))

    ; ---- Cocoa menu-bar quirk workaround -------------------------------------
    ; Qt's native macOS menu bar omits any top-level QMenu that has zero
    ; QActions at the moment it's synced into the NSMenu -- and with no
    ; menu-bar slot, the item can never be clicked, so `about-to-show-cb`
    ; above never fires either. That's a real deadlock for a menu populated
    ; lazily via demand-callback (framework's Windows/Tabs menu, see
    ; `group.rkt`'s `create-windows-menu`, always empty until opened) --
    ; confirmed via an isolated probe: an empty demand-callback-only menu
    ; never appears in `osascript`'s menu-bar-item enumeration at all.
    ; win32/gtk/cocoa render an empty top-level menu without issue. Fix:
    ; keep a hidden placeholder action whenever this menu would otherwise be
    ; truly empty at the Qt level, so it always carries >=1 native QAction.
    ; A separator does NOT work here -- measured: Qt's emptiness check for
    ; menu-bar sync ignores separators, so a separator-only menu is still
    ; treated as empty and stays omitted; a plain (blank-label, disabled)
    ; QAction does count. Kept out of item-table/items-in-order so
    ; `number`/delete-by-position keep reflecting only the logical
    ; (wx-level) item count.
    (define placeholder-action #f)
    (define (ensure-placeholder!)
      (unless placeholder-action
        (define a (shim_action_create qt-menu "" 0 #f #f))
        (shim_action_set_enabled a 0)
        (set! placeholder-action a)))
    (define (drop-placeholder!)
      (when placeholder-action
        (shim_menu_remove_action qt-menu placeholder-action)
        (set! placeholder-action #f)))
    (ensure-placeholder!)

    ; ---- top-frame resolution -----------------------------------------------
    (define (find-top-frame)
      (let loop ([p the-parent])
        (cond
          [(menu-bar-pred p) (send p get-top-window)]
          [(and p (is-a? p menu%)) (loop (send p get-parent-obj))]
          [else #f])))

    ; ---- append -------------------------------------------------------------
    ; id      : platform menu-item% token (hash key); #f for separators
    ; label   : display string
    ; help-or-sub : platform menu% if submenu, string/false otherwise
    ; checkable? : boolean
    (define/public (append id label help-or-sub checkable?)
      (drop-placeholder!)
      (define clean-label (clean-macos-shortcut-label label))
      (define action
        (if (and help-or-sub (object? help-or-sub))
            ; submenu — help-or-sub is platform menu% (or glue extending it)
            (shim_menu_add_submenu qt-menu clean-label
                                   (send help-or-sub get-qt-menu))
            ; leaf item
            (let ([cb (lambda (_ud)
                        (let ([frame (find-top-frame)])
                          (cond
                            [frame
                             (queue-event (send frame get-eventspace)
                               (lambda ()
                                 (send frame on-menu-command id)))]
                            ; Standalone popup-menu% (no menu-bar parent):
                            ; fall back to the mrpopup.rkt protocol via
                            ; `on-popup`/`popup-callback` (see `popup` below).
                            ; Consume `on-popup` and unpin before queuing —
                            ; `do-popup` below runs later, off the atomic
                            ; callback, so building the event there (not
                            ; here) keeps Rule 2 (post-only, never block).
                            [(and on-popup the-popup-callback)
                             (define do-popup on-popup)
                             (set! on-popup #f)
                             (when (eq? pinned-popup this) (set! pinned-popup #f))
                             (do-popup
                              (lambda ()
                                (define e (new popup-event% [event-type 'menu-popdown]))
                                (send e set-menu-id id)
                                (the-popup-callback this e)))])))])
              (hash-set! retained-callbacks id cb)
              (shim_action_create qt-menu clean-label (if checkable? 1 0) cb #f))))
      (hash-set! item-table id action)
      (order-push! id action))

    ; ---- append-separator ---------------------------------------------------
    (define/public (append-separator)
      (drop-placeholder!)
      (define sep-action (shim_menu_add_separator qt-menu))
      (order-push! #f sep-action))

    ; ---- delete (by id) -----------------------------------------------------
    (define/public (delete id)
      (define action (hash-ref item-table id #f))
      (when action
        (shim_menu_remove_action qt-menu action)
        (hash-remove! item-table id)
        (hash-remove! retained-callbacks id)
        (set! items-in-order
              (filter (lambda (p) (not (eq? (car p) id)))
                      items-in-order))
        (when (null? items-in-order) (ensure-placeholder!))))

    ; ---- delete-by-position -------------------------------------------------
    (define/public (delete-by-position pos)
      (when (< pos (length items-in-order))
        (define pair   (list-ref items-in-order pos))
        (define id     (car pair))
        (define action (cdr pair))
        (shim_menu_remove_action qt-menu action)
        (when id (hash-remove! item-table id) (hash-remove! retained-callbacks id))
        (order-remove-at! pos)
        (when (null? items-in-order) (ensure-placeholder!))))

    ; ---- enable (override — window% has 1-arg version) ----------------------
    (define/override (enable id on?)
      (define action (hash-ref item-table id #f))
      (when action
        (shim_action_set_enabled action (if on? 1 0))))

    ; ---- check / checked? ---------------------------------------------------
    (define/public (check id on?)
      (define action (hash-ref item-table id #f))
      (when action
        (shim_action_set_checked action (if on? 1 0))))

    (define/public (checked? id)
      (define action (hash-ref item-table id #f))
      (if action (not (= (shim_action_is_checked action) 0)) #f))

    ; ---- number -------------------------------------------------------------
    (define/public (number) (length items-in-order))

    ; ---- set-label ----------------------------------------------------------
    (define/public (set-label id str)
      (define action (hash-ref item-table id #f))
      (when action (shim_action_set_label action (clean-macos-shortcut-label str))))

    ; ---- popup --------------------------------------------------------------
    ; `cb` (window%'s popup-menu, e.g. wx/qt/window.rkt) is the eventspace
    ; queuing closure for the *invoking* window; `widget` is unused here
    ; (win32/gtk need it for OS-level menu positioning/anchoring, we don't).
    ; Pin `this` for the GC-safety reason documented at `pinned-popup`'s
    ; definition above, and stash `cb` as `on-popup` for the leaf-item
    ; callback's mrpopup.rkt fallback.
    (define/public (popup x y widget cb)
      (set! pinned-popup this)
      (set! on-popup cb)
      (shim_menu_popup qt-menu x y))

    ; ---- stubs required by glue / mrmenu ------------------------------------
    (define/public (select bm)          (void))
    (define/public (set-help-string m s)(void))
    (define/public (set-self-item i r)  (void))
    (define/public (get-item)           #f)
    (define/public (removing-item i)    (void))))
