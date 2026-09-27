#lang racket/base
; Qt group-panel% — a QGroupBox (native decorative frame + title) with a
; plain QWidget content area as its child. Mirrors win32/gtk's
; group-panel.rkt: a native frame control providing the border/label, and a
; separate client area that children actually parent to (same split as
; tab-panel%'s tabbar+content, docs/HACKING.md §21/§22).
;
; Init args mirror wx/win32 + wx/gtk's group-panel%, as received from
; wxpanel.rkt's wx-make-panel% after the panel glue consumes window-style:
; parent x y w h style label.
(require racket/class
         "../common/queue.rkt"
         "panel.rkt"
         "window.rkt"
         "utils.rkt")

(provide group-panel%)

(define group-panel%
  (class (panel-mixin window%)
    (init parent
          x y w h
          style
          label)

    (inherit get-width get-height)

    (define the-parent parent)

    (define parent-handle
      (if (and parent (object? parent) (is-a? parent window%))
          (send parent get-content-hwnd)
          (error 'qt-group-panel% "parent must be a Qt window%; got ~a" parent)))

    (define qt-handle (shim_group_panel_create parent-handle (or label "")))
    (define content-handle (shim_group_panel_get_content_widget qt-handle))

    (super-new [handle     qt-handle]
               [parent     parent]
               [eventspace (current-eventspace)]
               [no-show?   (and (memq 'deleted style) #t)])

    ; ---- sizing ----
    ; No QLayout: the content widget is positioned inside QGroupBox's own
    ; contentsMargins (the space its native frame/title reserve) -- same
    ; manual-positioning approach as tab-panel%'s tabbar/content split.

    (define/private (content-margins)
      (shim_group_panel_get_content_margins qt-handle))

    ; Seed a chrome-only size (zero content, just the title/border margins)
    ; right after construction. Without this, get-width/get-height read 0 at
    ; the very first do-get-graphical-min-size query (wxpanel.rkt), which
    ; runs BEFORE any real set-size call. get-client-size below then also
    ; clamps to 0, collapsing do-graphical-size's delta-w/delta-h --
    ; "(get-width) - client-w" -- from the true (l+r)/(t+b) chrome overhead
    ; down to 0. That silently starves this panel's own reported min-height
    ; by exactly its title-bar height, which is exactly what let
    ; DrRacket's "Choose Language" dialog's Collection Paths button row get
    ; placed past the group box's true bottom edge (§60.4,
    ; docs/HACKING.md). gtk avoids this because its group-panel% tracks the
    ; client offset from a live GtkAllocation signal instead of subtracting
    ; from a possibly-still-zero get-height/get-width; win32 avoids it by
    ; calling set-size directly in its own constructor. This mirrors win32's
    ; fix, seeded generically from content-margins instead of a hardcoded
    ; label height.
    (let-values ([(l t r b) (content-margins)])
      (set-size #f #f (+ l r) (+ t b)))

    (define/override (set-size x y nw nh)
      (super set-size x y nw nh)
      (when (and nw (> nw 0) nh (> nh 0))
        (shim_widget_set_geometry qt-handle
                                  (if (and x (>= x 0)) x 0)
                                  (if (and y (>= y 0)) y 0)
                                  nw nh)
        (define-values (l t r b) (content-margins))
        (shim_widget_set_geometry content-handle l t
                                  (max 0 (- nw l r)) (max 0 (- nh t b)))))

    ; The delta between get-width/get-height and this is the frame/title
    ; chrome overhead for wxpanel.rkt's generic do-graphical-size (same
    ; trick as tab-panel%'s get-client-size).
    (define/override (get-client-size wb hb)
      (define-values (l t r b) (content-margins))
      (when (getenv "PLT_QT_DEBUG")
        (eprintf "[qt-group-panel] get-client-size: get-w=~a get-h=~a l=~a t=~a r=~a b=~a\n"
                 (get-width) (get-height) l t r b))
      (set-box! wb (max 0 (- (get-width)  l r)))
      (set-box! hb (max 0 (- (get-height) t b))))

    ; ---- group-panel% contract (mirrors wx/win32, wx/gtk) ----

    (define/public (set-label lbl)
      (shim_group_panel_set_label qt-handle lbl))

    ; ---- platform interface ----

    (define/override (get-qt-handle)    qt-handle)
    (define/override (get-content-hwnd) content-handle)
    (define/public   (direct-show on?)  (void))
    (define/override (gets-focus?)      #f)))
