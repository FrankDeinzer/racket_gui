#lang racket/base
; Qt port of wx/gtk/gcwin.rkt -- DrRacket's GC indicator (register-collecting-
; blit/unregister-collecting-blits, consumed by framework/private/frame.rkt's
; gc-canvas). X11-only, mirroring gtk's own use-x11? gate (gtk's non-X11
; fallback path is not ported -- this machine runs X11, see docs/HACKING.md).
;
; This module is required unconditionally from wx/qt/canvas.rkt, which loads
; on all three OSes this backend targets -- so every libX11 binding below
; must degrade to a stub at *module-instantiation* time on Windows/macOS,
; not raise. `(ffi-lib ... #:fail (lambda () #f))` plus ffi/unsafe/define's
; `make-not-available` (get-ffi-obj calls the fail-thunk, not an exception,
; when the underlying lib value is #f) gives exactly that -- the same idiom
; wx/gtk/x11.rkt itself already uses for its own optional bindings.
;
; qt-init! (QApplication construction) has NOT run yet when this module is
; instantiated (platform.rkt calls it only after all of its requires,
; including this one transitively via canvas.rkt, are already loaded) -- so
; shim_get_x11_display, which dereferences qGuiApp, cannot be called at
; module top level. It is queried lazily instead, on first actual use, by
; which point a real canvas (hence platform-values, hence qt-init!) must
; already exist.
(require ffi/unsafe
         ffi/unsafe/define
         ffi/unsafe/alloc
         racket/draw/unsafe/cairo
         racket/class
         "utils.rkt")

(provide x11-gc-available?
         create-gc-window
         free-gc-window
         make-gc-show-desc
         make-gc-hide-desc
         bitmap->gc-bitmap)

; ---- libX11 (tolerant: absent on Windows/macOS) --------------------------

(define x11-lib (ffi-lib "libX11" '("6" "5" "") #:fail (lambda () #f)))

(define-ffi-definer define-x11 x11-lib #:default-make-fail make-not-available)

; Window/Pixmap are cpointer-wrapped (not plain _ulong) specifically so
; ffi/unsafe/alloc's allocator/deallocator wrap below can attach a finalizer
; to XCreatePixmap's result -- the same choice wx/gtk/x11.rkt makes, and for
; the same reason (a plain fixnum has nowhere to hang a finalizer). Cast to
; _ulong/_uintptr at the few points that need the raw XID (XGetWindowAttributes'
; window/root fields, cairo_xlib_surface_create's Drawable parameter, and
; wrapping the raw XID the shim hands back).
(define _Display _pointer)
(define _Visual _pointer)
(define _Window (_cpointer 'Window))
(define _Pixmap (_cpointer 'Pixmap))

(define (xid->Window u) (cast u _uintptr _Window))

(define-cstruct _XWindowAttributes
  ([x _int] [y _int]
   [width _int] [height _int]
   [border-width _int]
   [depth _int]
   [visual _Visual]
   [root _ulong]
   [win-class _int]
   [bit-gravity _int]
   [win-gravity _int]
   [backing-store _int]
   [backing-planes _ulong]
   [backing-pixel _ulong]
   [save-under _int]
   [colormap _ulong]
   [map-installed _int]
   [map-state _int]
   [all-event-masks _long]
   [your-event-mask _long]
   [do-not-propagate-mask _long]
   [override-redirect _int]
   [screen _pointer]))

(define-x11 XGetWindowAttributes
  (_fun _Display _Window _XWindowAttributes-pointer -> _int))

(define-x11 XFreePixmap (_fun _Display _Pixmap -> _void)
  #:wrap (deallocator cadr))
(define-x11 XCreatePixmap (_fun _Display _Window _int _int _int -> _Pixmap)
  #:wrap (lambda (proc)
           (lambda (dpy win w h d)
             (((allocator (lambda (pixmap) (XFreePixmap dpy pixmap)))
               (lambda () (proc dpy win w h d)))))))

; No finalization here -- as in gtk, the enclosing gc-window is destroyed
; explicitly (free-gc-window), never GC-collected out from under Qt/X11.
(define-x11 XDestroyWindow (_fun _Display _Window -> _void))
(define-x11 XCreateSimpleWindow (_fun _Display _Window
                                       _int _int _int _int
                                       _int _long _long
                                       -> _Window))

; Raw function pointers, not _fun-typed procedures: these three plus XFlush
; are never called from Racket directly -- they are baked into an
; unsafe-add-collect-callbacks opcode-vector (wx/qt/canvas.rkt) and invoked
; by the Racket CS runtime's own vector interpreter, during a live GC pause,
; without going through _fun's normal marshaling (Regel 1/2: this is the
; mechanism that lets the on/off toggle happen without touching Qt, Racket,
; or the event loop at all). See qt-shim/src/shim.cpp's "gc indicator"
; section and this file's GC-safety note below make-draw.
(define-x11 XSetWindowBackgroundPixmap _fpointer)
(define-x11 XMapRaised _fpointer)
(define-x11 XUnmapWindow _fpointer)
(define-x11 XFlush _fpointer)

; ---- Qt's X11 display connection (lazy -- see module comment) -----------

(define x11-display-box (box 'unset))

(define (get-x11-display)
  (define v (unbox x11-display-box))
  (if (eq? v 'unset)
      (let ([d (and x11-lib (shim_get_x11_display))])
        (set-box! x11-display-box d)
        d)
      v))

; #f under Wayland (shim_get_x11_display returns NULL) or on non-Linux (the
; #:fail-tolerant libX11 binding never resolved) -- wx/qt/canvas.rkt gates
; register-collecting-blit on this and no-ops otherwise (Regel 4).
(define (x11-gc-available?) (and (get-x11-display) #t))

(define (window-depth+visual display xid)
  (define attrs (cast (malloc _XWindowAttributes 'atomic-interior)
                       _pointer _XWindowAttributes-pointer))
  (XGetWindowAttributes display xid attrs)
  (values (XWindowAttributes-depth attrs) (XWindowAttributes-visual attrs)))

; ---- bitmap -> X11 Pixmap (registration time, ordinary Racket context) ---
; No screen-scale-factor handling (gtk's `sf`/`->screen`): this backend pins
; QT_SCALE_FACTOR=1 (qt-shim/src/shim.cpp, shim_app_init), so device-
; independent px == physical X11 px here, unlike gtk's raw-X11-below-GDK-
; scaling situation. `bms` (the bitmap's own backing-scale) is still
; respected -- it is a racket/draw-level property, independent of screen
; scaling, and gtk applies it the same way once its own `sf` is factored out.
(define (bitmap->gc-bitmap bm client-handle)
  (define display (get-x11-display))
  (define xid (shim_widget_get_x11_window client-handle))
  (define-values (depth visual) (window-depth+visual display (xid->Window xid)))
  (define w (send bm get-width))
  (define h (send bm get-height))
  (define bms (send bm get-backing-scale))
  (define cw (inexact->exact (ceiling w)))
  (define ch (inexact->exact (ceiling h)))
  (define pixmap (XCreatePixmap display (xid->Window xid) cw ch depth))
  (define s (cairo_xlib_surface_create display
                                        (cast pixmap _Pixmap _ulong)
                                        visual
                                        cw ch))
  (define cr (cairo_create s))
  (define pat (cairo_pattern_create_for_surface (send bm get-handle)))
  (cairo_pattern_set_matrix pat (make-cairo_matrix_t bms 0.0
                                                      0.0 bms
                                                      0.0 0.0))
  (cairo_set_source cr pat)
  (cairo_pattern_destroy pat)
  (cairo_rectangle cr 0 0 cw ch)
  (cairo_fill cr)
  (cairo_destroy cr)
  (cairo_surface_destroy s)
  pixmap)

; ---- gc-window lifecycle (registration/unregistration time only) --------
; Neither of these runs from inside the GC callback -- only the vectors
; built by make-gc-show-desc/make-gc-hide-desc below do.

(define (create-gc-window client-handle x y w h)
  (define display (get-x11-display))
  (define xid (xid->Window (shim_widget_get_x11_window client-handle)))
  (cons display
        (XCreateSimpleWindow display xid x y w h 0 0 0)))

(define (free-gc-window win)
  (XDestroyWindow (car win) (cdr win)))

; ---- GC-callback opcode vectors ------------------------------------------
; GC-safety: every function reachable from these vectors (XSetWindowBackground-
; Pixmap, XMapRaised, XUnmapWindow, XFlush) is a plain libX11 call operating
; only on the X11 protocol socket buffer -- no Racket call, no Racket
; allocation, no Qt event-loop/signal-slot machinery (no shim_pump). XFlush
; is used in place of gtk's gdk_display_flush for exactly this reason: it is
; the raw Xlib primitive gdk_display_flush itself wraps, with no GDK/GTK
; layer (hence no Qt/GTK cross-toolkit call) in between.
(define (make-draw win gc-bitmap w h)
  (vector
   (vector 'ptr_ptr_ptr->void
           XSetWindowBackgroundPixmap
           (car win)
           (cdr win)
           gc-bitmap)))

(define (make-flush)
  (vector
   (vector 'ptr_ptr_ptr->void XFlush (get-x11-display) #f #f)))

(define (vector* . l)
  (for*/vector ([v (in-list l)] [e (in-vector v)]) e))

(define (make-gc-show-desc win gc-bitmap w h)
  (vector*
   (make-draw win gc-bitmap w h)
   (vector
    (vector 'ptr_ptr_ptr->void
            XMapRaised
            (car win)
            (cdr win)
            #f))
   (make-flush)))

(define (make-gc-hide-desc win gc-bitmap w h)
  (vector*
   ;; draw the ``off'' bitmap so we can flush immediately
   (make-draw win gc-bitmap w h)
   (make-flush)
   (vector
    ;; hide the window; it may take a while for the underlying canvas
    ;; to refresh:
    (vector 'ptr_ptr_ptr->void
            XUnmapWindow
            (car win)
            (cast (cdr win) _Window _pointer)
            #f))))
