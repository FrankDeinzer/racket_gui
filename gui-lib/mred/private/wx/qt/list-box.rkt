#lang racket/base
; Qt list-box% — wraps a QListWidget via the shim.
; Single-column only: this backend does not implement report-mode/multi-
; column lists (no driver needs it yet; see docs/HACKING.md's widget-
; addition checklist). Column-related methods below are contract-satisfying
; no-ops, mirroring how wx/gtk and wx/win32 handle their own unsupported
; corners of this same bounced method set (wxlitem.rkt's wx-list-box%).
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
    ; shim-side via QSignalBlocker (shim_list_box_select/set_current).
    (define ignore-click? #f)

    (define kind-int
      (case kind
        [(multiple) 1]
        [(extended) 2]
        [else 0]))

    ; selection-fn captures `this`; runs later in atomic + queued context.
    (define selection-fn
      (lambda (ud)
        (unless ignore-click?
          (queue-event the-eventspace
                       (lambda ()
                         (callback this
                                   (make-object control-event% 'list-box)))))))

    (define parent-handle
      (if (and parent (object? parent) (is-a? parent window%))
          (send parent get-content-hwnd)
          (error 'qt-list-box% "parent must be a Qt window%; got ~a" parent)))

    (define qt-handle
      (shim_list_box_create parent-handle kind-int selection-fn #f))

    (super-new [handle     qt-handle]
               [parent     parent]
               [eventspace the-eventspace])

    ; Racket-side box list for set-data/get-data — Qt has no slot for
    ; arbitrary Racket values on a QListWidgetItem.
    (define data (map (lambda (c) (box #f)) choices))

    (set! ignore-click? #t)
    (for ([s (in-list choices)]) (shim_list_box_append qt-handle s))
    (set! ignore-click? #f)

    ; ---- sizing ----

    (define/override (set-size x y nw nh)
      (super set-size x y nw nh)
      (when (and nw (> nw 0) nh (> nh 0))
        (shim_widget_set_geometry qt-handle
                                  (if (and x (>= x 0)) x 0)
                                  (if (and y (>= y 0)) y 0)
                                  nw nh)))

    ; ---- list-box% contract (mirrors wx/win32, wx/gtk) ----

    (define/public (number) (shim_list_box_count qt-handle))

    (define/public (get-data i) (unbox (list-ref data i)))
    (define/public (set-data i v) (set-box! (list-ref data i) v))

    (define/public (set-string i s [col 0])
      (shim_list_box_set_string qt-handle i s))

    ; Defined as append*/exposed as append (racket/class rename form) so the
    ; method body's own use of racket/list's `append` isn't shadowed by the
    ; method name — same convention wx/gtk's list-box% uses for this reason.
    (public [append* append])
    (define append*
      (case-lambda
       [(s) (append* s #f)]
       [(s v)
        (set! data (append data (list (box v))))
        (shim_list_box_append qt-handle s)]))

    (define/public (delete i)
      (set! data (append (take data i) (drop data (add1 i))))
      (shim_list_box_delete qt-handle i))

    (define/public (clear)
      (set! data null)
      (set! ignore-click? #t)
      (shim_list_box_clear qt-handle)
      (set! ignore-click? #f))

    (define/public (set choices . more-choices)
      (set! ignore-click? #t)
      (shim_list_box_clear qt-handle)
      (for ([s (in-list choices)]) (shim_list_box_append qt-handle s))
      (set! data (map (lambda (s) (box #f)) choices))
      (set! ignore-click? #f))

    (define/public (get-selections)
      (let ([n (shim_list_box_selected_count qt-handle)])
        (for/list ([i (in-range n)])
          (shim_list_box_selected_at qt-handle i))))

    (define/public (get-selection)
      (let ([l (get-selections)])
        (if (null? l) -1 (car l))))

    (define/public (selected? i)
      (not (zero? (shim_list_box_is_selected qt-handle i))))

    ; extend? (default #t) keeps any existing selection, matching gtk's
    ; contract; #f clears other rows first (exclusive select).
    (define/public select
      (case-lambda
       [(i) (do-select i #t #t)]
       [(i on?) (do-select i on? #t)]
       [(i on? extend?) (do-select i on? extend?)]))

    (define/private (do-select i on? extend?)
      (when (and on? (not extend?))
        (for ([j (in-range (shim_list_box_count qt-handle))])
          (unless (= j i) (shim_list_box_select qt-handle j 0))))
      (shim_list_box_select qt-handle i (if on? 1 0)))

    (define/public (set-selection i)
      (shim_list_box_set_current qt-handle i))

    (define/public (set-first-visible-item i)
      (shim_list_box_scroll_to qt-handle i))

    (define/public (get-first-item)
      (shim_list_box_first_visible qt-handle))

    (define/public (number-of-visible-items)
      (shim_list_box_visible_count qt-handle))

    ; ---- multi-column stubs (single-column QListWidget only) ----

    (define/public (get-column-order) '(0))
    (define/public (set-column-order l) (void))
    (define/public (set-column-label i l) (void))
    (define/public (set-column-size i w mn mx) (void))
    (define/public (get-column-size i) (values 100 0 10000))
    (define/public (delete-column i) (void))
    (define/public (append-column l) (void))

    ; ---- platform interface ----

    (define/public (set-border on?)   (void))
    (define/public (direct-show on?)  (void))
    (define/override (is-shown?)        #t)
    (define/override (gets-focus?)      #t)
    (define/override (get-qt-handle)    qt-handle)
    (define/public   (command e)        (callback this e))
    (define/override (get-top-frame)
      (let loop ([p the-parent])
        (if (and p (object? p) (is-a? p window%))
            (let ([pp (send p get-parent)])
              (if pp (loop pp) p))
            #f)))))
