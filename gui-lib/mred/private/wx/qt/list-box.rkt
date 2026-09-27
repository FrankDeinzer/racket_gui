#lang racket/base
; Qt list-box% — wraps a QListWidget (single-column) or QTreeWidget
; (multi-column) via the shim.
;
; Dual-path, additive (§60.6): the original single-column QListWidget path
; (shim_list_box_*, RacketListWidget in qt-shim/src/shim.cpp, including the
; §60.4 sizeHint cap) is untouched byte-for-byte -- every branch below that
; takes the `tree?` #f arm calls exactly the same shim functions in exactly
; the same order as before this file was extended for §60.6. The multi-
; column case (Package Manager: gui-pkg-manager-lib's by-list.rkt/
; by-installed.rkt) dispatches to a completely separate shim export family
; (shim_list_tree_*, RacketTreeWidget) instead.
;
; `columns` always arrives with at least one label (even the plain
; single-column default case) -- per mred's wxlitem.rkt glue layer -- so the
; tree path is NOT simply "(> (length columns) 1)": an explicit
; 'column-headers style with a single column must also route to the tree
; path (it wants a visible header, which QListWidget cannot show).
;
; Init args mirror wx/win32 + wx/gtk's list-box%, as received from
; wxlitem.rkt's wx-internal-list-box% after make-control% consumes
; window-style:
;   parent cb label kind x y w h choices style font label-font columns column-order
(require racket/class
         racket/list
         "../common/event.rkt"
         "../common/queue.rkt"
         "window.rkt"
         "utils.rkt")

(provide list-box%)

(define list-box%
  (class window%
    (init parent cb label kind x y w h choices style font
          label-font columns column-order)

    (define the-eventspace (current-eventspace))
    (define the-parent parent)
    (define callback cb)

    ; Suppresses the selection-changed callback during programmatic bulk
    ; repopulation (clear/set), mirroring gtk's ignore-click?/win32's
    ; suppress-callback. Single select/set-current calls are instead guarded
    ; shim-side via QSignalBlocker (shim_list_box_select/set_current, and
    ; likewise shim_list_tree_select/set_current).
    (define ignore-click? #f)

    (define kind-int
      (case kind
        [(multiple) 1]
        [(extended) 2]
        [else 0]))

    ; ---- §60.6 dual-path dispatch --------------------------------------
    (define num-cols (length columns))
    (define headers? (and (memq 'column-headers style) #t))
    (define tree? (or (> num-cols 1) headers?))
    (define clickable-headers? (and tree? (memq 'clickable-headers style) #t))
    (define reorderable-headers? (and tree? (memq 'reorderable-headers style) #t))

    ; selection-fn captures `this`; runs later in atomic + queued context.
    (define selection-fn
      (lambda (ud)
        (unless ignore-click?
          (queue-event the-eventspace
                       (lambda ()
                         (callback this
                                   (make-object control-event% 'list-box)))))))

    ; Header-click callback (tree path only, and only when 'clickable-headers
    ; is set): posts a column-control-event%, exactly what by-list.rkt's
    ; sort-by! callback expects (e.g. is-a? column-control-event% -> get-column).
    ; Regel 2: only enqueues, never calls back synchronously.
    (define header-click-fn
      (lambda (ud col)
        (queue-event the-eventspace
                     (lambda ()
                       (callback this
                                 (new column-control-event%
                                      [event-type 'list-box-column]
                                      [column col]
                                      [time-stamp (current-milliseconds)]))))))

    (define parent-handle
      (if (and parent (object? parent) (is-a? parent window%))
          (send parent get-content-hwnd)
          (error 'qt-list-box% "parent must be a Qt window%; got ~a" parent)))

    (define qt-handle
      (if tree?
          (shim_list_tree_create parent-handle kind-int num-cols selection-fn #f)
          (shim_list_box_create parent-handle kind-int selection-fn #f)))

    (super-new [handle     qt-handle]
               [parent     parent]
               [eventspace the-eventspace]
               [no-show?   (and (memq 'deleted style) #t)])

    (when tree?
      (shim_list_tree_set_headers_visible qt-handle (if headers? 1 0))
      (for ([col-label (in-list columns)] [i (in-naturals)])
        (shim_list_tree_set_column_label qt-handle i col-label))
      (when reorderable-headers?
        (shim_list_tree_set_sections_movable qt-handle 1))
      (when clickable-headers?
        (shim_list_tree_set_header_clicked_cb qt-handle header-click-fn #f))
      (when column-order
        (set-column-order column-order)))

    ; Racket-side box list for set-data/get-data — Qt has no slot for
    ; arbitrary Racket values on a QListWidgetItem/QTreeWidgetItem.
    (define data (map (lambda (c) (box #f)) choices))

    (set! ignore-click? #t)
    (if tree?
        (for ([s (in-list choices)]) (shim_list_tree_append_row qt-handle s))
        (for ([s (in-list choices)]) (shim_list_box_append qt-handle s)))
    (set! ignore-click? #f)
    ; After choices, not before: sizeHint() should reflect populated rows.
    (send this seed-size-from-native-hint)

    ; ---- sizing ----

    (define/override (set-size x y nw nh)
      (super set-size x y nw nh)
      (when (and nw (> nw 0) nh (> nh 0))
        (shim_widget_set_geometry qt-handle
                                  (if (and x (>= x 0)) x 0)
                                  (if (and y (>= y 0)) y 0)
                                  nw nh)))

    ; ---- list-box% contract (mirrors wx/win32, wx/gtk) ----

    (define/public (number)
      (if tree? (shim_list_tree_count qt-handle) (shim_list_box_count qt-handle)))

    (define/public (get-data i) (unbox (list-ref data i)))
    (define/public (set-data i v) (set-box! (list-ref data i) v))

    (define/public (set-string i s [col 0])
      (if tree?
          (shim_list_tree_set_cell qt-handle i col s)
          (shim_list_box_set_string qt-handle i s)))

    ; Defined as append*/exposed as append (racket/class rename form) so the
    ; method body's own use of racket/list's `append` isn't shadowed by the
    ; method name — same convention wx/gtk's list-box% uses for this reason.
    (public [append* append])
    (define append*
      (case-lambda
       [(s) (append* s #f)]
       [(s v)
        (set! data (append data (list (box v))))
        (if tree?
            (shim_list_tree_append_row qt-handle s)
            (shim_list_box_append qt-handle s))]))

    (define/public (delete i)
      (set! data (append (take data i) (drop data (add1 i))))
      (if tree?
          (shim_list_tree_delete_row qt-handle i)
          (shim_list_box_delete qt-handle i)))

    (define/public (clear)
      (set! data null)
      (set! ignore-click? #t)
      (if tree? (shim_list_tree_clear qt-handle) (shim_list_box_clear qt-handle))
      (set! ignore-click? #f))

    ; `choices` fills column 0; each further list in `more-choices` fills the
    ; next column (1, 2, ...) row-for-row -- the shape the Package Manager
    ; relies on (by-list.rkt's sort-pkg-list! calls `set` with 8 lists at
    ; once for its 8 columns). Single-column callers never pass more-choices,
    ; so that path is unchanged.
    (define/public (set choices . more-choices)
      (set! ignore-click? #t)
      (if tree?
          (begin
            (shim_list_tree_clear qt-handle)
            (for ([s (in-list choices)]) (shim_list_tree_append_row qt-handle s))
            (for ([col-list (in-list more-choices)] [col (in-naturals 1)])
              (for ([s (in-list col-list)] [i (in-naturals)])
                (shim_list_tree_set_cell qt-handle i col s))))
          (begin
            (shim_list_box_clear qt-handle)
            (for ([s (in-list choices)]) (shim_list_box_append qt-handle s))))
      (set! data (map (lambda (s) (box #f)) choices))
      (set! ignore-click? #f))

    (define/public (get-selections)
      (let ([n (if tree?
                   (shim_list_tree_selected_count qt-handle)
                   (shim_list_box_selected_count qt-handle))])
        (for/list ([i (in-range n)])
          (if tree?
              (shim_list_tree_selected_at qt-handle i)
              (shim_list_box_selected_at qt-handle i)))))

    (define/public (get-selection)
      (let ([l (get-selections)])
        (if (null? l) -1 (car l))))

    (define/public (selected? i)
      (not (zero? (if tree?
                      (shim_list_tree_is_selected qt-handle i)
                      (shim_list_box_is_selected qt-handle i)))))

    ; extend? (default #t) keeps any existing selection, matching gtk's
    ; contract; #f clears other rows first (exclusive select).
    (define/public select
      (case-lambda
       [(i) (do-select i #t #t)]
       [(i on?) (do-select i on? #t)]
       [(i on? extend?) (do-select i on? extend?)]))

    (define/private (do-select i on? extend?)
      (when (and on? (not extend?))
        (for ([j (in-range (number))])
          (unless (= j i)
            (if tree?
                (shim_list_tree_select qt-handle j 0)
                (shim_list_box_select qt-handle j 0)))))
      (if tree?
          (shim_list_tree_select qt-handle i (if on? 1 0))
          (shim_list_box_select qt-handle i (if on? 1 0))))

    (define/public (set-selection i)
      (if tree?
          (shim_list_tree_set_current qt-handle i)
          (shim_list_box_set_current qt-handle i)))

    (define/public (set-first-visible-item i)
      (if tree?
          (shim_list_tree_scroll_to qt-handle i)
          (shim_list_box_scroll_to qt-handle i)))

    (define/public (get-first-item)
      (if tree?
          (shim_list_tree_first_visible qt-handle)
          (shim_list_box_first_visible qt-handle)))

    (define/public (number-of-visible-items)
      (if tree?
          (shim_list_tree_visible_count qt-handle)
          (shim_list_box_visible_count qt-handle)))

    ; ---- multi-column contract (§60.6) ----------------------------------
    ; Real for the tree path (QHeaderView-backed); the single-column list
    ; path keeps its original, deliberately trivial answers (there really is
    ; exactly one column, and no caller in this backend ever reads them --
    ; docs/HACKING.md §60.6/§60.9).

    (define/public (get-column-order)
      (if tree?
          (for/list ([pos (in-range num-cols)])
            (shim_list_tree_column_at_visual_pos qt-handle pos))
          '(0)))

    (define/public (set-column-order l)
      (if tree?
          (for ([logical (in-list l)] [pos (in-naturals)])
            (shim_list_tree_move_column qt-handle logical pos))
          (void)))

    (define/public (set-column-label i l)
      (if tree? (shim_list_tree_set_column_label qt-handle i l) (void)))

    (define/public (set-column-size i w mn mx)
      (if tree? (shim_list_tree_set_column_width qt-handle i w mn mx) (void)))

    (define/public (get-column-size i)
      (if tree?
          (shim_list_tree_get_column_width qt-handle i)
          (values 100 0 10000)))

    (define/public (delete-column i)
      (if tree?
          (begin (shim_list_tree_delete_column qt-handle i)
                 (set! num-cols (sub1 num-cols)))
          (void)))

    (define/public (append-column l)
      (if tree?
          (begin (shim_list_tree_append_column qt-handle l)
                 (set! num-cols (add1 num-cols)))
          (void)))

    ; ---- platform interface ----

    (define/public (set-border on?)   (void))
    (define/public (direct-show on?)  (void))
    (define/override (gets-focus?)      #t)
    (define/override (get-qt-handle)    qt-handle)
    (define/public   (command e)        (callback this e))
    (define/override (get-top-frame)
      (let loop ([p the-parent])
        (if (and p (object? p) (is-a? p window%))
            (let ([pp (send p get-parent)])
              (if pp (loop pp) p))
            #f)))))
