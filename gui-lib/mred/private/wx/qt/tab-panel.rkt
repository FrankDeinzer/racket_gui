#lang racket/base
; Qt tab-panel% — a QTabBar tab strip + a plain QWidget content area, both
; siblings parented to a container QWidget. NOT QTabWidget: both gtk's and
; win32's tab-panel.rkt keep exactly ONE wx-managed client area and let the
; native control supply only tab selection + a changed callback -- the
; children of the tab-panel are managed entirely by the shared mred/wx layer
; (Preferences swaps visible panels itself via panel:single%'s active-child),
; oblivious to which tab they "belong" to. docs/HACKING.md §21.
;
; Positioning is explicit (mirrors win32's MoveWindow math), not a Qt
; layout -- so get-client-size is pure arithmetic and never has to guess
; whether a QLayout has activated yet (a real risk for the first layout pass
; before a dialog's initial show()).
;
; Init args mirror wx/win32 + wx/gtk's tab-panel%, as received from
; wxpanel.rkt's wx-make-tab%/wx-make-panel% after the panel glue consumes
; window-style: parent x y w h style labels.
(require racket/class
         "../common/event.rkt"
         "../common/queue.rkt"
         "panel.rkt"
         "window.rkt"
         "utils.rkt")

(provide tab-panel%)

(define tab-panel%
  (class (panel-mixin window%)
    (init parent
          x y w h
          style
          labels)

    (inherit get-width get-height)

    (define the-eventspace (current-eventspace))
    (define the-parent parent)
    (define callback void)
    (define count (length labels))

    ; changed-fn captures `this`; runs later in atomic + queued context.
    ; Mirrors button%/choice%/radio-box%: the shim's C++ lambda only calls
    ; cb(ud); Racket reads the new selection back separately via get-selection.
    (define changed-fn
      (lambda (ud)
        (queue-event the-eventspace
                     (lambda ()
                       (callback this
                                 (make-object control-event% 'tab-panel))))))

    (define parent-handle
      (if (and parent (object? parent) (is-a? parent window%))
          (send parent get-content-hwnd)
          (error 'qt-tab-panel% "parent must be a Qt window%; got ~a" parent)))

    (define qt-handle
      (shim_tab_panel_create parent-handle changed-fn #f))

    (define tabbar-handle  (shim_tab_panel_get_tabbar_widget qt-handle))
    (define content-handle (shim_tab_panel_get_content_widget qt-handle))

    (for ([l (in-list labels)])
      (shim_tab_panel_append qt-handle (if (string? l) l "")))

    (super-new [handle     qt-handle]
               [parent     parent]
               [eventspace the-eventspace])

    ; ---- sizing ----
    ; No QLayout: tabbar gets its own sizeHint height at the top, content
    ; gets the rest. Both widgets are real QWidget children of qt-handle, so
    ; this is exactly win32's tab-panel.rkt MoveWindow math, just phrased via
    ; the existing generic shim_widget_set_geometry/get_size_hint calls
    ; instead of bespoke tab-panel-only shim functions.

    (define/private (tab-height)
      (define-values (w h) (shim_widget_get_size_hint tabbar-handle))
      h)

    (define/override (set-size x y nw nh)
      (super set-size x y nw nh)
      (when (getenv "PLT_QT_DEBUG")
        (eprintf "[qt-tab-panel] set-size x=~a y=~a nw=~a nh=~a\n" x y nw nh))
      (when (and nw (> nw 0) nh (> nh 0))
        (shim_widget_set_geometry qt-handle
                                  (if (and x (>= x 0)) x 0)
                                  (if (and y (>= y 0)) y 0)
                                  nw nh)
        (define th (tab-height))
        (when (getenv "PLT_QT_DEBUG")
          (eprintf "[qt-tab-panel] tab-height=~a content-geom=(0,~a,~a,~a)\n"
                    th th nw (max 0 (- nh th))))
        (shim_widget_set_geometry tabbar-handle 0 0 nw th)
        (shim_widget_set_geometry content-handle 0 th nw (max 0 (- nh th)))))

    ; The delta between get-width/get-height and this determines the tab
    ; strip's chrome overhead for the generic panel-sizing math in
    ; wxpanel.rkt's do-graphical-size (same trick as gtk's
    ; infer-client-delta) -- no separate "reserve room for the tab strip"
    ; step needed anywhere else.
    (define/override (get-client-size wb hb)
      (set-box! wb (get-width))
      (set-box! hb (max 0 (- (get-height) (tab-height)))))

    ; ---- tab-panel% contract (mirrors wx/win32, wx/gtk) ----

    ; Defined as append*/exposed as append (racket/class rename form) --
    ; racket/list's append would otherwise shadow this method inside its own
    ; body, same convention as this backend's choice%/list-box%.
    (public [append* append])
    (define (append* lbl)
      (set! count (add1 count))
      (shim_tab_panel_append qt-handle lbl))

    (define/public (delete i)
      (set! count (sub1 count))
      (shim_tab_panel_delete qt-handle i))

    (define/public (set choices)
      (for ([_ (in-range count)]) (shim_tab_panel_delete qt-handle 0))
      (set! count 0)
      (for ([l (in-list choices)]) (append* l))
      (when (> count 0)
        (shim_tab_panel_set_selection qt-handle 0)))

    (define/public (set-label i str)
      (shim_tab_panel_set_label qt-handle i str))

    (define/public (get-selection)
      (shim_tab_panel_get_selection qt-handle))

    (define/public (set-selection i)
      (shim_tab_panel_set_selection qt-handle i))

    (define/public (number) count)

    ; No native focus-vs-selection distinction in QTabBar (unlike win32's
    ; TCM_SETCURFOCUS/TCM_GETCURFOCUS) -- mirrors gtk's simpler mapping onto
    ; get-selection/set-selection, which no driver's use of tab-panel% needs
    ; to distinguish from real tab focus.
    (define/public (button-focus n)
      (if (= n -1)
          (get-selection)
          (begin (set-selection n) n)))

    ; wx-make-tab% (wxpanel.rkt) overrides these via override* -- they must
    ; exist here, mirrors gtk's/win32's own no-op defaults (neither driver
    ; needs drag-reorder or close-button tabs).
    (define/public (on-choice-reorder new-positions) (void))
    (define/public (on-choice-close pos)             (void))

    (define/public (set-callback cb) (set! callback cb))

    ; ---- platform interface ----

    (define/override (get-qt-handle)    qt-handle)
    (define/override (get-content-hwnd) content-handle)
    (define/public   (direct-show on?)  (void))
    (define/override (is-shown?)        #t)
    (define/override (gets-focus?)      #t)))
