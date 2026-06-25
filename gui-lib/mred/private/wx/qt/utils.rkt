#lang racket/base
; FFI bindings for the Qt shim DLL.
(require ffi/unsafe
         racket/path)

(provide shim-lib
         shim_version
         shim_app_init
         shim_app_quit
         shim_pump
         shim_events_pending
         shim_window_create
         shim_window_set_title
         shim_window_set_size
         shim_window_show
         shim_window_destroy
         shim_window_get_content_widget
         shim_widget_set_geometry
         shim_canvas_create
         shim_canvas_set_mouse_cb
         shim_canvas_set_key_cb
         shim_canvas_set_focus_cb
         shim_canvas_blit_argb
         shim_canvas_request_repaint
         shim_canvas_get_width
         shim_canvas_get_height
         shim_canvas_destroy
         shim_panel_create
         shim_button_create
         shim_button_destroy
         _callback_t
         _mouse_cb_t
         _key_cb_t
         _focus_cb_t)

; Locate the shim DLL.
; Path from this file: 7 levels up = project root, then qt-shim/build/…
(define shim-lib
  (let* ([here (path-only (collection-file-path "utils.rkt"
                                                "mred" "private" "wx" "qt"))]
         [dll  (simplify-path
                (build-path here
                            ".." ".." ".." ".." ".." ".." ".."
                            "qt-shim" "build" "windows-x64" "Debug"
                            "racketqtshim"))])
    (ffi-lib (path->string dll))))

; C-callable callback type (called atomically from within processEvents).
; The body must only enqueue work; never block or trigger GC.
(define _callback_t
  (_fun #:atomic? #t _pointer -> _void))

; Mouse callback: ud, event-type, x, y, buttons-bitmask, mods-bitmask
(define _mouse_cb_t
  (_fun #:atomic? #t _pointer _int _int _int _int _int -> _void))

; Key callback: ud, event-type(0=press,1=release), Qt::Key, text-char(unicode), mods
(define _key_cb_t
  (_fun #:atomic? #t _pointer _int _int _int _int -> _void))

; Focus callback: ud, gained(1=focus-in, 0=focus-out)
(define _focus_cb_t
  (_fun #:atomic? #t _pointer _int -> _void))

(define shim_version
  (get-ffi-obj "shim_version" shim-lib (_fun -> _string)))

(define shim_app_init
  (get-ffi-obj "shim_app_init" shim-lib (_fun -> _void)))

(define shim_app_quit
  (get-ffi-obj "shim_app_quit" shim-lib (_fun -> _void)))

(define shim_pump
  (get-ffi-obj "shim_pump" shim-lib (_fun _int -> _void)))

(define shim_events_pending
  (get-ffi-obj "shim_events_pending" shim-lib (_fun -> _int)))

(define shim_window_create
  (get-ffi-obj "shim_window_create" shim-lib
               (_fun _callback_t _pointer -> _pointer)))

(define shim_window_set_title
  (get-ffi-obj "shim_window_set_title" shim-lib
               (_fun _pointer _string/utf-8 -> _void)))

(define shim_window_set_size
  (get-ffi-obj "shim_window_set_size" shim-lib
               (_fun _pointer _int _int -> _void)))

(define shim_window_show
  (get-ffi-obj "shim_window_show" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_window_destroy
  (get-ffi-obj "shim_window_destroy" shim-lib
               (_fun _pointer -> _void)))

(define shim_window_get_content_widget
  (get-ffi-obj "shim_window_get_content_widget" shim-lib
               (_fun _pointer -> _pointer)))

(define shim_widget_set_geometry
  (get-ffi-obj "shim_widget_set_geometry" shim-lib
               (_fun _pointer _int _int _int _int -> _void)))

(define shim_canvas_create
  (get-ffi-obj "shim_canvas_create" shim-lib
               (_fun _pointer _callback_t _pointer -> _pointer)))

(define shim_canvas_set_mouse_cb
  (get-ffi-obj "shim_canvas_set_mouse_cb" shim-lib
               (_fun _pointer _mouse_cb_t _pointer -> _void)))

(define shim_canvas_set_key_cb
  (get-ffi-obj "shim_canvas_set_key_cb" shim-lib
               (_fun _pointer _key_cb_t _pointer -> _void)))

(define shim_canvas_set_focus_cb
  (get-ffi-obj "shim_canvas_set_focus_cb" shim-lib
               (_fun _pointer _focus_cb_t _pointer -> _void)))

(define shim_canvas_blit_argb
  (get-ffi-obj "shim_canvas_blit_argb" shim-lib
               (_fun _pointer _bytes _int _int _int -> _void)))

(define shim_canvas_request_repaint
  (get-ffi-obj "shim_canvas_request_repaint" shim-lib
               (_fun _pointer -> _void)))

(define shim_canvas_get_width
  (get-ffi-obj "shim_canvas_get_width" shim-lib
               (_fun _pointer -> _int)))

(define shim_canvas_get_height
  (get-ffi-obj "shim_canvas_get_height" shim-lib
               (_fun _pointer -> _int)))

(define shim_canvas_destroy
  (get-ffi-obj "shim_canvas_destroy" shim-lib
               (_fun _pointer -> _void)))

(define shim_panel_create
  (get-ffi-obj "shim_panel_create" shim-lib
               (_fun _pointer -> _pointer)))

(define shim_button_create
  (get-ffi-obj "shim_button_create" shim-lib
               (_fun _pointer _string/utf-8 _callback_t _pointer -> _pointer)))

(define shim_button_destroy
  (get-ffi-obj "shim_button_destroy" shim-lib
               (_fun _pointer -> _void)))
