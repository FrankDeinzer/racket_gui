#lang racket/base
; Qt platform module — exports platform-values for Racket's GUI toolkit.
; Spike implementation: frame%, canvas%, button%, check-box%, list-box% are
; real; rest are stubs.
(require racket/class
         racket/draw
         "../common/default-procs.rkt"
         "frame.rkt"
         "canvas.rkt"
         "button.rkt"
         "check-box.rkt"
         "list-box.rkt"
         "dialog.rkt"
         "panel.rkt"
         "window.rkt"
         "menu-bar.rkt"
         "menu.rkt"
         "menu-item.rkt"
         "message.rkt"
         "filedialog.rkt"
         "queue.rkt")

(provide (protect-out platform-values))

; ---- stub class factory ---------------------------------------------------
; Stub classes extend window% so the glue layers (wx-make-window%, make-item%)
; can inherit is-shown-to-root?, is-enabled-to-root?, etc.
(define (make-stub-class name)
  (class window%
    (init-rest args)
    (define the-parent (if (pair? args) (car args) #f))
    (super-new [handle #f] [parent the-parent])
    ; Widget interface stubs so glue layers can `inherit` them:
    (define/public (command e)       (void))
    (define/public (set-border on?)  (void))
    (define/public (set-value v)     (void))
    (define/public (get-value)       #f)
    ; variadic: button-style callers pass (label); tab-panel%'s get-tab-widget
    ; path (mrpanel.rkt) passes (index label) since tab-panel-available? => #t
    ; claims a native tab widget -- mirrors `append`'s rest-arg treatment above.
    (define/public (set-label . args) (void))
    (define/public (get-label)        "")
    (define/public (set-selection i) (void))
    (define/public (get-selection)   -1)
    (define/public (clear)           (void))
    (define/public (append . args)   (void))
    (define/public (defaulting on?)  (void))
    (define/public (has-border?)     #f)
    (define/public (on-choice-reorder new-positions) (void))
    (define/public (on-choice-close pos)             (void))
    ; list-box specific methods inherited by wx-internal-list-box%
    (define/public (get-first-item)         0)
    (define/public (set-first-visible-item i) (void))
    (define/public (number-of-visible-items) 0)
    ; radio-box/choice/list-box: item count
    (define/public (number)                  0)
    ; gauge
    (define/public (set-gauge-value v)       (void))
    (define/public (get-gauge-value)         0)
    ; slider
    (define/public (set-slider-value v)      (void))
    (define/public (get-slider-value)        0)
    ; button-focus for radio-box/tab-panel
    (define/public (button-focus i)          -1)
    ; char-to: NOT here — added by wx-make-window% (wxwindow.rkt) via public*
    ; label setting for controls (button-style set-label)
    (define/public (set-item n label)        (void))
    (define/public (get-item-label n)        "")
    ; canvas group-panel
    (define/public (adopt-child c)           (void))
    (define/public (get-label-position)      'horizontal)
    (define/public (set-label-position pos)  (void))
    (define/public (set-item-cursor x y)     (void))
    ; menu-related methods (needed by wx-menu-bar% and wx-menu% glue)
    (define/public (delete label pos)                (void))
    (define/public (delete-by-position pos)          (void))
    ; append is already defined above (as (append s)) — redefine as case-lambda
    ; to support both (append s) and (append menu title) arities
    (define/public (enable-top pos on?)              (void))
    ; on-combo-select: expected by wxtextfield.rkt via override* on combo controls
    (define/public (on-combo-select i)               (void))
    ; set-callback: mrpanel.rkt sends this to the tab widget (get-tab-widget)
    (define/public (set-callback cb)                 (void))))

; ---- unimplemented stubs ---------------------------------------------------

(define canvas-panel%  (make-stub-class 'canvas-panel%))
; check-box% is the real implementation (check-box.rkt); imported above
(define choice%        (make-stub-class 'choice%))
; dialog% is the real implementation (dialog.rkt); imported above
; gauge%: non-erroring stub (visual-only progress bar, e.g. DrRacket splash)
(define gauge%
  (class window%
    (init-rest args)
    (define the-parent (if (pair? args) (car args) #f))
    (super-new [handle #f] [parent the-parent])
    (define range 100)
    (define value 0)
    (define/public (get-range)   range)
    (define/public (set-range r) (set! range r))
    (define/public (get-value)   value)
    (define/public (set-value v) (set! value v))))
(define group-panel%   (make-stub-class 'group-panel%))
; list-box% is the real implementation (list-box.rkt); imported above
; menu%, menu-bar%, menu-item% are real implementations (menu*.rkt); imported above
; message% is the real implementation (message.rkt); imported above
; printer-dc% must NOT extend window% — it's a DC class.
; doc+page-check-mixin (racket/draw/private/page-dc) applies define/override to
; start-doc/end-doc/start-page/end-page and all draw methods.
; We extend bitmap-dc% which provides all those as real methods; gdi.rkt wraps us.
(define printer-dc%
  (class object%
    (init [parent #f])
    (super-new)
    (define/public (start-doc s)       #f)
    (define/public (end-doc)           (void))
    (define/public (start-page)        (void))
    (define/public (end-page)          (void))
    (define/public (draw-bitmap bm dx dy [s 'solid] [c #f] [m #f]) #f)
    (define/public (draw-bitmap-section bm dx dy sx sy sw sh [s 'solid] [c #f] [m #f]) #f)
    (define/public (draw-polygon pts [x 0] [y 0] [fill 'odd-even]) (void))
    (define/public (draw-lines pts [x 0] [y 0]) (void))
    (define/public (draw-path p [x 0] [y 0] [fill 'odd-even]) (void))
    (define/public (draw-ellipse x y w h) (void))
    (define/public (draw-arc x y w h s e) (void))
    (define/public (draw-text t x y [c? #f] [offset 0] [angle 0.0]) (void))
    (define/public (draw-spline x1 y1 x2 y2 x3 y3) (void))
    (define/public (draw-rounded-rectangle x y w h [r -0.25]) (void))
    (define/public (draw-rectangle x y w h) (void))
    (define/public (draw-point x y) (void))
    (define/public (draw-line x1 y1 x2 y2) (void))
    (define/public (clear) (void))
    (define/public (erase) (void))))
(define radio-box%     (make-stub-class 'radio-box%))
(define slider%        (make-stub-class 'slider%))
(define tab-panel%     (make-stub-class 'tab-panel%))

; ---- minimal item% and clipboard/cursor stubs ------------------------------

(define item%
  (class window%
    (init-rest args)
    (super-new [handle #f] [parent #f])
    (define/public   (command e) (void))
    (define/override (gets-focus?) #t)))

(define clipboard-driver%
  (class object%
    (init [x-selection? #f])
    (super-new)
    (define/public (get-data fmt)        #f)
    (define/public (set-data fmt data)   (void))
    (define/public (get-text-data)       #f)
    (define/public (set-text-data s)     (void))
    (define/public (clear-data)          (void))
    (define/public (get-client)          #f)
    (define/public (set-client c event)  (void))
    (define/public (same-client? c)      #f)))

(define cursor-driver%
  (class object%
    (super-new)
    (define/public (ok?)                                   #t)
    (define/public (set-standard sym)                      (void))
    (define/public (set-image image mask hx hy)            (void))
    (define/public (get-handle)                            #f)))

; ---- function stubs -------------------------------------------------------

(define (can-show-print-setup?)          #f)
(define (show-print-setup parent)        #f)
; id is `this` from platform menu-item%'s (id) method. Since Racket's `this`
; is always the most-derived object, id IS the wx-menu-item% glue instance,
; which has get-mred.  We guard with is-a? to avoid errors on unexpected types.
(define (id-to-menu-item id)
  (and (object? id) (is-a? id menu-item%)
       (send id get-mred)))
; file-selector: real implementation (filedialog.rkt); imported above
(define (is-color-display?)              #t)
(define (get-display-depth)              32)
(define (has-x-selection?)               #f)
(define (hide-cursor)                    (void))
(define (bell)                           (void))
(define (flush-display)                  (void))
; ⚑ FLAG: no shim query for the real global cursor position/button-state yet
; (gtk/win32/cocoa call into their native APIs). Stubbed at (0,0)/no-buttons
; with the correct 0-arg/2-values contract so callers don't crash; revisit
; if real position is needed (e.g. context-menu placement).
(define (get-current-mouse-state)
  (values (make-object point% 0 0) '()))
(define (cancel-quit)                    (void))
(define (get-control-font-face)          "Arial")
(define (get-control-font-size)          11)
(define (get-control-font-size-in-pixels?) #f)
(define (get-double-click-time)          500)
(define (location->window x y)          #f)
(define (shortcut-visible-in-label? [? #f]) #t)
(define (unregister-collecting-blit canvas) (void))
(define (register-collecting-blit canvas x y w h on off ox oy fx fy) (void))
(define (find-graphical-system-path what)
  (case what
    [(init-file) (find-system-path 'init-file)]
    [else #f]))
(define (play-sound file async?) #f)
(define (font-from-user-platform-mode)  #f)
(define (get-font-from-user msg parent  init) #f)
(define (color-from-user-platform-mode) 'dialog)
(define (get-color-from-user msg parent init) #f)
(define (get-highlight-background-color)
  (make-object color% 0 120 215))
(define (get-highlight-text-color)
  (make-object color% 255 255 255))
(define (get-label-foreground-color)
  (make-object color% 0 0 0))
(define (get-label-background-color)
  (make-object color% 240 240 240))
(define (make-screen-bitmap w h)
  (make-object bitmap% w h #f #t))
(define (make-gl-bitmap w h ctx)  #f)
(define (check-for-break)        #f)
(define (key-symbol-to-menu-key sym) #f)
(define (needs-grow-box-spacer?) #f)
(define (graphical-system-type)  'qt)
(define (tab-panel-available?)   #t)
(define (white-on-black-panel-scheme?)
  (let ([bg (get-label-background-color)]
        [fg (get-label-foreground-color)])
    (< (+ (* .2126 (/ (send bg red) 255))
          (* .7152 (/ (send bg green) 255))
          (* .0722 (/ (send bg blue) 255)))
       (+ (* .2126 (/ (send fg red) 255))
          (* .7152 (/ (send fg green) 255))
          (* .0722 (/ (send fg blue) 255))))))

; ---- init Qt ---------------------------------------------------------------

; Called once when this module is first required (i.e. when platform-values
; is called for the first time by wx/platform.rkt).
(qt-init!)
(qt-start-event-pump)

; ---- platform-values -------------------------------------------------------

(define (platform-values)
  (values
   button%
   canvas%
   canvas-panel%
   check-box%
   choice%
   clipboard-driver%
   cursor-driver%
   dialog%
   frame%
   gauge%
   group-panel%
   item%
   list-box%
   menu%
   menu-bar%
   menu-item%
   message%
   panel%
   printer-dc%
   radio-box%
   slider%
   tab-panel%
   window%
   can-show-print-setup?
   show-print-setup
   id-to-menu-item
   file-selector
   is-color-display?
   get-display-depth
   has-x-selection?
   hide-cursor
   bell
   display-size
   display-origin
   display-count
   display-bitmap-resolution
   flush-display
   get-current-mouse-state
   fill-private-color
   cancel-quit
   get-control-font-face
   get-control-font-size
   get-control-font-size-in-pixels?
   get-double-click-time
   file-creator-and-type
   location->window
   shortcut-visible-in-label?
   unregister-collecting-blit
   register-collecting-blit
   find-graphical-system-path
   play-sound
   get-panel-background
   font-from-user-platform-mode
   get-font-from-user
   color-from-user-platform-mode
   get-color-from-user
   special-option-key
   special-control-key
   any-control+alt-is-altgr
   get-highlight-background-color
   get-highlight-text-color
   get-label-foreground-color
   get-label-background-color
   make-screen-bitmap
   make-gl-bitmap
   check-for-break
   key-symbol-to-menu-key
   needs-grow-box-spacer?
   graphical-system-type
   white-on-black-panel-scheme?
   tab-panel-available?))
