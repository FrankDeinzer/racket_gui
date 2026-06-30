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
         "window.rkt"
         "utils.rkt")

(provide menu%
         register-menu-bar-predicate!)

; Capture racket/base's append before it is shadowed by define/public (append ...)
; inside the class body.
(define list-append append)

; menu-bar% predicate — avoids circular require between menu.rkt and menu-bar.rkt.
; menu-bar.rkt registers itself at load time.
(define menu-bar-pred (lambda (x) #f))
(define (register-menu-bar-predicate! pred)
  (set! menu-bar-pred pred))

(define menu%
  (class window%
    ; popup-label, popup-callback, font: used by GTK popup menus; ignored here
    (init [popup-label #f] [popup-callback #f] [font #f])
    (super-new [handle #f] [parent #f])

    ; ---- Qt handle ----------------------------------------------------------
    (define qt-menu (shim_menu_create (or popup-label "")))

    (define/public (get-qt-menu) qt-menu)

    ; ---- parent tracking ----------------------------------------------------
    (define the-parent #f)
    (define/public (set-parent p) (set! the-parent p))
    (define/public (get-parent-obj) the-parent)

    ; ---- item tracking ------------------------------------------------------
    ; item-table: id → QAction* (leaf items only)
    (define item-table (make-hasheq))
    ; items-in-order: list of (id . QAction*) — id is #f for separators
    (define items-in-order '())

    (define (order-push! id action)
      (set! items-in-order (list-append items-in-order (list (cons id action)))))
    (define (order-remove-at! pos)
      (define before (take items-in-order pos))
      (define after  (drop items-in-order (+ pos 1)))
      (set! items-in-order (list-append before after)))

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
      (define action
        (if (and help-or-sub (object? help-or-sub))
            ; submenu — help-or-sub is platform menu% (or glue extending it)
            (shim_menu_add_submenu qt-menu label
                                   (send help-or-sub get-qt-menu))
            ; leaf item
            (let ([cb (lambda (_ud)
                        (let ([frame (find-top-frame)])
                          (when frame
                            (queue-event (send frame get-eventspace)
                              (lambda ()
                                (send frame on-menu-command id))))))])
              (shim_action_create label (if checkable? 1 0) cb #f))))
      (hash-set! item-table id action)
      (order-push! id action))

    ; ---- append-separator ---------------------------------------------------
    (define/public (append-separator)
      (define sep-action (shim_menu_add_separator qt-menu))
      (order-push! #f sep-action))

    ; ---- delete (by id) -----------------------------------------------------
    (define/public (delete id)
      (define action (hash-ref item-table id #f))
      (when action
        (shim_menu_remove_action qt-menu action)
        (hash-remove! item-table id)
        (set! items-in-order
              (filter (lambda (p) (not (eq? (car p) id)))
                      items-in-order))))

    ; ---- delete-by-position -------------------------------------------------
    (define/public (delete-by-position pos)
      (when (< pos (length items-in-order))
        (define pair   (list-ref items-in-order pos))
        (define id     (car pair))
        (define action (cdr pair))
        (shim_menu_remove_action qt-menu action)
        (when id (hash-remove! item-table id))
        (order-remove-at! pos)))

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
      (when action (shim_action_set_label action str)))

    ; ---- popup --------------------------------------------------------------
    (define/public (popup x y widget cb)
      (shim_menu_popup qt-menu x y))

    ; ---- stubs required by glue / mrmenu ------------------------------------
    (define/public (select bm)          (void))
    (define/public (set-help-string m s)(void))
    (define/public (set-self-item i r)  (void))
    (define/public (get-item)           #f)
    (define/public (removing-item i)    (void))))
