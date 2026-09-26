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
         shim_window_set_resize_cb
         shim_window_show
         shim_window_destroy
         shim_window_get_content_widget
         shim_window_set_menubar
         shim_window_maximize
         shim_window_is_maximized
         shim_window_iconize
         shim_window_is_iconized
         shim_window_fullscreen
         shim_window_is_fullscreen
         shim_widget_set_geometry
         shim_widget_set_focus
         shim_widget_client_to_screen
         shim_widget_get_size_hint
         shim_widget_set_enabled
         shim_widget_set_visible
         shim_canvas_create
         shim_canvas_set_mouse_cb
         shim_canvas_set_key_cb
         shim_canvas_set_focus_cb
         shim_canvas_set_wheel_cb
         shim_canvas_blit_argb
         shim_canvas_request_repaint
         shim_canvas_get_width
         shim_canvas_get_height
         shim_canvas_destroy
         shim_panel_create
         shim_button_create
         shim_button_destroy
         shim_button_set_label
         shim_menubar_create
         shim_menubar_add_menu
         shim_menubar_enable_at
         shim_menubar_remove_at
         shim_menu_create
         shim_menu_set_about_to_show_cb
         shim_menu_set_about_to_hide_cb
         shim_menu_set_title
         shim_menu_add_submenu
         shim_menu_add_separator
         shim_menu_remove_action
         shim_menu_popup
         shim_menu_debug_dump
         shim_action_create
         shim_action_set_enabled
         shim_action_set_label
         shim_action_set_checked
         shim_action_is_checked
         shim_label_create
         shim_label_set_text
         shim_check_box_create
         shim_check_box_set_checked
         shim_check_box_get_checked
         shim_list_box_create
         shim_list_box_clear
         shim_list_box_append
         shim_list_box_set_string
         shim_list_box_delete
         shim_list_box_count
         shim_list_box_is_selected
         shim_list_box_select
         shim_list_box_set_current
         shim_list_box_selected_count
         shim_list_box_selected_at
         shim_list_box_scroll_to
         shim_list_box_first_visible
         shim_list_box_visible_count
         shim_slider_create
         shim_slider_set_value
         shim_slider_get_value
         shim_gauge_create
         shim_gauge_set_range
         shim_gauge_get_range
         shim_gauge_set_value
         shim_gauge_get_value
         shim_scrollbar_create
         shim_scrollbar_set_range
         shim_scrollbar_set_value
         shim_scrollbar_get_value
         shim_choice_create
         shim_choice_append
         shim_choice_clear
         shim_choice_delete
         shim_choice_count
         shim_choice_set_selection
         shim_choice_get_selection
         shim_radio_box_create
         shim_radio_box_append_button
         shim_radio_box_set_selection
         shim_radio_box_get_selection
         shim_radio_box_enable_button
         shim_radio_box_button_focus
         shim_file_dialog_create
         shim_printer_show_print_dialog
         shim_printer_show_page_setup_dialog
         shim_printer_create
         shim_printer_destroy
         shim_printer_set_page_setup
         shim_printer_get_page_setup
         shim_printer_set_output_pdf
         shim_printer_begin_job
         shim_printer_draw_page
         shim_printer_new_page
         shim_printer_end_job
         shim_tab_panel_create
         shim_tab_panel_get_tabbar_widget
         shim_tab_panel_get_content_widget
         shim_tab_panel_append
         shim_tab_panel_delete
         shim_tab_panel_set_label
         shim_tab_panel_set_selection
         shim_tab_panel_get_selection
         shim_tab_panel_count
         shim_group_panel_create
         shim_group_panel_get_content_widget
         shim_group_panel_get_content_margins
         shim_group_panel_set_label
         shim_bell
         shim_clipboard_set_text
         shim_clipboard_get_text
         shim_clipboard_has_text
         shim_clipboard_supports_selection
         shim_clipboard_set_image
         shim_clipboard_has_image
         shim_clipboard_image_size
         shim_clipboard_get_image_argb
         shim_control_font_face
         shim_control_font_size
         shim_double_click_time
         shim_cursor_create_standard
         shim_cursor_create_from_argb
         shim_widget_set_cursor
         shim_widget_unset_cursor
         shim_get_mouse_state
         shim_get_x11_display
         shim_widget_get_x11_window
         _callback_t
         _mouse_cb_t
         _key_cb_t
         _focus_cb_t
         _wheel_cb_t
         _resize_cb_t
         _file_dialog_cb_t
         _printer_dialog_cb_t)

; Locate the shim library.
; Path from this file: 7 levels up = project root, then qt-shim/build/<preset>/
; Windows uses a multi-config generator (Debug subdir); Ninja-based builds do not.
(define shim-lib
  (let* ([here (path-only (collection-file-path "utils.rkt"
                                                "mred" "private" "wx" "qt"))]
         [root (build-path here ".." ".." ".." ".." ".." ".." "..")]
         [dll  (simplify-path
                (case (system-type 'os)
                  [(windows)
                   (build-path root "qt-shim" "build" "windows-x64" "Debug"
                                "racketqtshim.dll")]
                  [(macosx)
                   (build-path root "qt-shim" "build" "macos-arm64"
                                "libracketqtshim.dylib")]
                  [else
                   (build-path root "qt-shim" "build" "linux-x64"
                                "libracketqtshim.so")]))])
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

; Mouse wheel callback: ud, dx, dy (Qt angleDelta, eighths of a degree; one
; notch = 120, dy > 0 = away from the user = scroll up), mods-bitmask.
(define _wheel_cb_t
  (_fun #:atomic? #t _pointer _int _int _int -> _void))

; Native top-level resize callback: ud, new width, new height.
(define _resize_cb_t
  (_fun #:atomic? #t _pointer _int _int -> _void))

; File dialog result callback: ud, path (raw pointer -- NULL on cancel; the
; Racket wrapper in filedialog.rkt casts it to _string/utf-8 itself, since
; _string/utf-8's coretype (bytes) can't be wrapped in _or-null).
(define _file_dialog_cb_t
  (_fun #:atomic? #t _pointer _pointer -> _void))

; Printer/page-setup dialog result callback: ud, accepted (1=QDialog::Accepted).
(define _printer_dialog_cb_t
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

(define shim_window_set_resize_cb
  (get-ffi-obj "shim_window_set_resize_cb" shim-lib
               (_fun _pointer _resize_cb_t _pointer -> _void)))

(define shim_window_show
  (get-ffi-obj "shim_window_show" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_window_destroy
  (get-ffi-obj "shim_window_destroy" shim-lib
               (_fun _pointer -> _void)))

(define shim_window_get_content_widget
  (get-ffi-obj "shim_window_get_content_widget" shim-lib
               (_fun _pointer -> _pointer)))

(define shim_window_maximize
  (get-ffi-obj "shim_window_maximize" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_window_is_maximized
  (get-ffi-obj "shim_window_is_maximized" shim-lib
               (_fun _pointer -> _int)))

(define shim_window_iconize
  (get-ffi-obj "shim_window_iconize" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_window_is_iconized
  (get-ffi-obj "shim_window_is_iconized" shim-lib
               (_fun _pointer -> _int)))

(define shim_window_fullscreen
  (get-ffi-obj "shim_window_fullscreen" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_window_is_fullscreen
  (get-ffi-obj "shim_window_is_fullscreen" shim-lib
               (_fun _pointer -> _int)))

(define shim_widget_set_geometry
  (get-ffi-obj "shim_widget_set_geometry" shim-lib
               (_fun _pointer _int _int _int _int -> _void)))

(define shim_widget_set_focus
  (get-ffi-obj "shim_widget_set_focus" shim-lib
               (_fun _pointer -> _void)))

; QWidget::mapToGlobal(QPoint(x,y)) -> (values screen-x screen-y).
(define shim_widget_client_to_screen
  (get-ffi-obj "shim_widget_client_to_screen" shim-lib
               (_fun _pointer _int _int
                     (out-x : (_ptr o _int))
                     (out-y : (_ptr o _int))
                     -> _void
                     -> (values out-x out-y))))

; QWidget::sizeHint() -> (values width height). Used by item-based widgets
; (button%/message%/check-box%/list-box%) to seed window%'s w/h right after
; construction (docs/HACKING.md §18.2).
(define shim_widget_get_size_hint
  (get-ffi-obj "shim_widget_get_size_hint" shim-lib
               (_fun _pointer
                     (out-w : (_ptr o _int))
                     (out-h : (_ptr o _int))
                     -> _void
                     -> (values out-w out-h))))

; QWidget::setEnabled() -- toolkit-level parent disable while a modal
; dialog is open (docs/HACKING.md §18.3), mirroring win32's EnableWindow
; and gtk's gtk_widget_set_sensitive.
(define shim_widget_set_enabled
  (get-ffi-obj "shim_widget_set_enabled" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_widget_set_visible
  (get-ffi-obj "shim_widget_set_visible" shim-lib
               (_fun _pointer _int -> _void)))

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

(define shim_canvas_set_wheel_cb
  (get-ffi-obj "shim_canvas_set_wheel_cb" shim-lib
               (_fun _pointer _wheel_cb_t _pointer -> _void)))

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
               (_fun _pointer _int -> _pointer)))

(define shim_button_create
  (get-ffi-obj "shim_button_create" shim-lib
               (_fun _pointer _string/utf-8 _callback_t _pointer -> _pointer)))

(define shim_button_destroy
  (get-ffi-obj "shim_button_destroy" shim-lib
               (_fun _pointer -> _void)))

(define shim_button_set_label
  (get-ffi-obj "shim_button_set_label" shim-lib
               (_fun _pointer _string/utf-8 -> _void)))

; ---- menu-bar ---------------------------------------------------------------

(define shim_menubar_create
  (get-ffi-obj "shim_menubar_create" shim-lib
               (_fun -> _pointer)))

(define shim_window_set_menubar
  (get-ffi-obj "shim_window_set_menubar" shim-lib
               (_fun _pointer _pointer -> _void)))

(define shim_menubar_add_menu
  (get-ffi-obj "shim_menubar_add_menu" shim-lib
               (_fun _pointer _pointer -> _void)))

(define shim_menubar_enable_at
  (get-ffi-obj "shim_menubar_enable_at" shim-lib
               (_fun _pointer _int _int -> _void)))

(define shim_menubar_remove_at
  (get-ffi-obj "shim_menubar_remove_at" shim-lib
               (_fun _pointer _int -> _void)))

; ---- menu -------------------------------------------------------------------

(define shim_menu_create
  (get-ffi-obj "shim_menu_create" shim-lib
               (_fun _string/utf-8 -> _pointer)))

(define shim_menu_set_title
  (get-ffi-obj "shim_menu_set_title" shim-lib
               (_fun _pointer _string/utf-8 -> _void)))

(define shim_menu_set_about_to_show_cb
  (get-ffi-obj "shim_menu_set_about_to_show_cb" shim-lib
               (_fun _pointer _callback_t _pointer -> _void)))

(define shim_menu_set_about_to_hide_cb
  (get-ffi-obj "shim_menu_set_about_to_hide_cb" shim-lib
               (_fun _pointer _callback_t _pointer -> _void)))

(define shim_menu_add_submenu
  (get-ffi-obj "shim_menu_add_submenu" shim-lib
               (_fun _pointer _string/utf-8 _pointer -> _pointer)))

(define shim_menu_add_separator
  (get-ffi-obj "shim_menu_add_separator" shim-lib
               (_fun _pointer -> _pointer)))

(define shim_menu_remove_action
  (get-ffi-obj "shim_menu_remove_action" shim-lib
               (_fun _pointer _pointer -> _void)))

(define shim_menu_popup
  (get-ffi-obj "shim_menu_popup" shim-lib
               (_fun _pointer _int _int -> _void)))

; Gated (PLT_QT_DEBUG) on-demand dump of a QMenu's actions().size() and
; per-action enabled/checked state to stderr. No-op if the env var is unset.
(define shim_menu_debug_dump
  (get-ffi-obj "shim_menu_debug_dump" shim-lib
               (_fun _pointer -> _void)))

; ---- action -----------------------------------------------------------------

(define shim_action_create
  (get-ffi-obj "shim_action_create" shim-lib
               (_fun _pointer _string/utf-8 _int _callback_t _pointer -> _pointer)))

(define shim_action_set_enabled
  (get-ffi-obj "shim_action_set_enabled" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_action_set_label
  (get-ffi-obj "shim_action_set_label" shim-lib
               (_fun _pointer _string/utf-8 -> _void)))

(define shim_action_set_checked
  (get-ffi-obj "shim_action_set_checked" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_action_is_checked
  (get-ffi-obj "shim_action_is_checked" shim-lib
               (_fun _pointer -> _int)))

; ---- label ------------------------------------------------------------------

(define shim_label_create
  (get-ffi-obj "shim_label_create" shim-lib
               (_fun _pointer _string/utf-8 -> _pointer)))

(define shim_label_set_text
  (get-ffi-obj "shim_label_set_text" shim-lib
               (_fun _pointer _string/utf-8 -> _void)))

; ---- check-box (check-box%) --------------------------------------------

(define shim_check_box_create
  (get-ffi-obj "shim_check_box_create" shim-lib
               (_fun _pointer _string/utf-8 _callback_t _pointer -> _pointer)))

(define shim_check_box_set_checked
  (get-ffi-obj "shim_check_box_set_checked" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_check_box_get_checked
  (get-ffi-obj "shim_check_box_get_checked" shim-lib
               (_fun _pointer -> _int)))

; ---- list-box (list-box%) -----------------------------------------------

(define shim_list_box_create
  (get-ffi-obj "shim_list_box_create" shim-lib
               (_fun _pointer _int _callback_t _pointer -> _pointer)))

(define shim_list_box_clear
  (get-ffi-obj "shim_list_box_clear" shim-lib
               (_fun _pointer -> _void)))

(define shim_list_box_append
  (get-ffi-obj "shim_list_box_append" shim-lib
               (_fun _pointer _string/utf-8 -> _void)))

(define shim_list_box_set_string
  (get-ffi-obj "shim_list_box_set_string" shim-lib
               (_fun _pointer _int _string/utf-8 -> _void)))

(define shim_list_box_delete
  (get-ffi-obj "shim_list_box_delete" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_list_box_count
  (get-ffi-obj "shim_list_box_count" shim-lib
               (_fun _pointer -> _int)))

(define shim_list_box_is_selected
  (get-ffi-obj "shim_list_box_is_selected" shim-lib
               (_fun _pointer _int -> _int)))

(define shim_list_box_select
  (get-ffi-obj "shim_list_box_select" shim-lib
               (_fun _pointer _int _int -> _void)))

(define shim_list_box_set_current
  (get-ffi-obj "shim_list_box_set_current" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_list_box_selected_count
  (get-ffi-obj "shim_list_box_selected_count" shim-lib
               (_fun _pointer -> _int)))

(define shim_list_box_selected_at
  (get-ffi-obj "shim_list_box_selected_at" shim-lib
               (_fun _pointer _int -> _int)))

(define shim_list_box_scroll_to
  (get-ffi-obj "shim_list_box_scroll_to" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_list_box_first_visible
  (get-ffi-obj "shim_list_box_first_visible" shim-lib
               (_fun _pointer -> _int)))

(define shim_list_box_visible_count
  (get-ffi-obj "shim_list_box_visible_count" shim-lib
               (_fun _pointer -> _int)))

; ---- slider (slider%) ------------------------------------------------------

(define shim_slider_create
  (get-ffi-obj "shim_slider_create" shim-lib
               (_fun _pointer _int _int _int _int _callback_t _pointer -> _pointer)))

(define shim_slider_set_value
  (get-ffi-obj "shim_slider_set_value" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_slider_get_value
  (get-ffi-obj "shim_slider_get_value" shim-lib
               (_fun _pointer -> _int)))

; ---- gauge (gauge%) ---------------------------------------------------------

(define shim_gauge_create
  (get-ffi-obj "shim_gauge_create" shim-lib
               (_fun _pointer _int _int _int -> _pointer)))

(define shim_gauge_set_range
  (get-ffi-obj "shim_gauge_set_range" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_gauge_get_range
  (get-ffi-obj "shim_gauge_get_range" shim-lib
               (_fun _pointer -> _int)))

(define shim_gauge_set_value
  (get-ffi-obj "shim_gauge_set_value" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_gauge_get_value
  (get-ffi-obj "shim_gauge_get_value" shim-lib
               (_fun _pointer -> _int)))

; ---- scrollbar (canvas% do-set-scrollbars / manual scroll API) -------------

(define shim_scrollbar_create
  (get-ffi-obj "shim_scrollbar_create" shim-lib
               (_fun _pointer _int _callback_t _pointer -> _pointer)))

(define shim_scrollbar_set_range
  (get-ffi-obj "shim_scrollbar_set_range" shim-lib
               (_fun _pointer _int _int _int -> _void)))

(define shim_scrollbar_set_value
  (get-ffi-obj "shim_scrollbar_set_value" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_scrollbar_get_value
  (get-ffi-obj "shim_scrollbar_get_value" shim-lib
               (_fun _pointer -> _int)))

; ---- choice (choice%) -------------------------------------------------------

(define shim_choice_create
  (get-ffi-obj "shim_choice_create" shim-lib
               (_fun _pointer _callback_t _pointer -> _pointer)))

(define shim_choice_append
  (get-ffi-obj "shim_choice_append" shim-lib
               (_fun _pointer _string/utf-8 -> _void)))

(define shim_choice_clear
  (get-ffi-obj "shim_choice_clear" shim-lib
               (_fun _pointer -> _void)))

(define shim_choice_delete
  (get-ffi-obj "shim_choice_delete" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_choice_count
  (get-ffi-obj "shim_choice_count" shim-lib
               (_fun _pointer -> _int)))

(define shim_choice_set_selection
  (get-ffi-obj "shim_choice_set_selection" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_choice_get_selection
  (get-ffi-obj "shim_choice_get_selection" shim-lib
               (_fun _pointer -> _int)))

; ---- radio-box (radio-box%) -------------------------------------------------

(define shim_radio_box_create
  (get-ffi-obj "shim_radio_box_create" shim-lib
               (_fun _pointer _int _callback_t _pointer -> _pointer)))

(define shim_radio_box_append_button
  (get-ffi-obj "shim_radio_box_append_button" shim-lib
               (_fun _pointer _string/utf-8 -> _void)))

(define shim_radio_box_set_selection
  (get-ffi-obj "shim_radio_box_set_selection" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_radio_box_get_selection
  (get-ffi-obj "shim_radio_box_get_selection" shim-lib
               (_fun _pointer -> _int)))

(define shim_radio_box_enable_button
  (get-ffi-obj "shim_radio_box_enable_button" shim-lib
               (_fun _pointer _int _int -> _void)))

(define shim_radio_box_button_focus
  (get-ffi-obj "shim_radio_box_button_focus" shim-lib
               (_fun _pointer _int -> _int)))

; ---- file dialog (get-file / put-file) -----------------------------------

; parent (may be #f/NULL), mode (0=open,1=save), caption, directory,
; filename, extension, filter (Qt name-filter syntax), result callback + ud.
;
; The `cb' parameter is declared _pointer, not _file_dialog_cb_t: a _fun
; ctype's Racket->C conversion unconditionally re-wraps whatever value it's
; given through make-ffi-callback (see ffi/unsafe.rkt's `_cprocedure*`), even
; if that value is already a callback pointer -- so it both (a) rejects an
; already-built callback with a "expected: procedure?" contract error, and
; (b) if given a plain procedure instead, allocates a brand-new native
; trampoline on every single call. filedialog.rkt builds exactly one
; persistent callback via (function-ptr ... _file_dialog_cb_t) at module
; load and passes that same pointer on every call; declaring this parameter
; _pointer lets it pass through unchanged instead of being re-wrapped
; (docs/HACKING.md §19 -- a fresh trampoline per call crashed reproducibly
; after ~3 file dialogs).
(define shim_file_dialog_create
  (get-ffi-obj "shim_file_dialog_create" shim-lib
               (_fun _pointer _int _string/utf-8 _string/utf-8 _string/utf-8
                     _string/utf-8 _string/utf-8 _pointer _pointer
                     -> _void)))

; ---- printer (printer-dc% / show-print-setup) --------------------------
; `cb' is _pointer, not _printer_dialog_cb_t, for the same reason as the file
; dialog above: printer-dc.rkt builds one persistent trampoline via
; (function-ptr ... _printer_dialog_cb_t) at module load, keyed by an integer
; id cast through `ud' -- never a fresh callback per call (docs/HACKING.md §19).
(define shim_printer_show_print_dialog
  (get-ffi-obj "shim_printer_show_print_dialog" shim-lib
               (_fun _pointer _pointer _pointer _pointer -> _void)))

(define shim_printer_show_page_setup_dialog
  (get-ffi-obj "shim_printer_show_page_setup_dialog" shim-lib
               (_fun _pointer _pointer _pointer _pointer -> _void)))

(define shim_printer_create
  (get-ffi-obj "shim_printer_create" shim-lib (_fun -> _pointer)))

(define shim_printer_destroy
  (get-ffi-obj "shim_printer_destroy" shim-lib (_fun _pointer -> _void)))

(define shim_printer_set_page_setup
  (get-ffi-obj "shim_printer_set_page_setup" shim-lib
               (_fun _pointer _int _int -> _void)))

(define shim_printer_get_page_setup
  (get-ffi-obj "shim_printer_get_page_setup" shim-lib
               (_fun _pointer (out-landscape : (_ptr o _int))
                     -> (id : _int)
                     -> (values id out-landscape))))

(define shim_printer_set_output_pdf
  (get-ffi-obj "shim_printer_set_output_pdf" shim-lib
               (_fun _pointer _string/utf-8 -> _void)))

(define shim_printer_begin_job
  (get-ffi-obj "shim_printer_begin_job" shim-lib
               (_fun _pointer _string/utf-8 -> _pointer)))

(define shim_printer_draw_page
  (get-ffi-obj "shim_printer_draw_page" shim-lib
               (_fun _pointer _pointer _bytes _int _int _int -> _void)))

(define shim_printer_new_page
  (get-ffi-obj "shim_printer_new_page" shim-lib (_fun _pointer -> _int)))

(define shim_printer_end_job
  (get-ffi-obj "shim_printer_end_job" shim-lib (_fun _pointer -> _void)))

; ---- tab-panel (tab-panel%) --------------------------------------------

(define shim_tab_panel_create
  (get-ffi-obj "shim_tab_panel_create" shim-lib
               (_fun _pointer _callback_t _pointer -> _pointer)))

(define shim_tab_panel_get_tabbar_widget
  (get-ffi-obj "shim_tab_panel_get_tabbar_widget" shim-lib
               (_fun _pointer -> _pointer)))

(define shim_tab_panel_get_content_widget
  (get-ffi-obj "shim_tab_panel_get_content_widget" shim-lib
               (_fun _pointer -> _pointer)))

(define shim_tab_panel_append
  (get-ffi-obj "shim_tab_panel_append" shim-lib
               (_fun _pointer _string/utf-8 -> _void)))

(define shim_tab_panel_delete
  (get-ffi-obj "shim_tab_panel_delete" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_tab_panel_set_label
  (get-ffi-obj "shim_tab_panel_set_label" shim-lib
               (_fun _pointer _int _string/utf-8 -> _void)))

(define shim_tab_panel_set_selection
  (get-ffi-obj "shim_tab_panel_set_selection" shim-lib
               (_fun _pointer _int -> _void)))

(define shim_tab_panel_get_selection
  (get-ffi-obj "shim_tab_panel_get_selection" shim-lib
               (_fun _pointer -> _int)))

(define shim_tab_panel_count
  (get-ffi-obj "shim_tab_panel_count" shim-lib
               (_fun _pointer -> _int)))

; ---- group-panel (group-panel%) ----------------------------------------

(define shim_group_panel_create
  (get-ffi-obj "shim_group_panel_create" shim-lib
               (_fun _pointer _string/utf-8 -> _pointer)))

(define shim_group_panel_get_content_widget
  (get-ffi-obj "shim_group_panel_get_content_widget" shim-lib
               (_fun _pointer -> _pointer)))

(define shim_group_panel_get_content_margins
  (get-ffi-obj "shim_group_panel_get_content_margins" shim-lib
               (_fun _pointer
                     (out-l : (_ptr o _int))
                     (out-t : (_ptr o _int))
                     (out-r : (_ptr o _int))
                     (out-b : (_ptr o _int))
                     -> _void
                     -> (values out-l out-t out-r out-b))))

(define shim_group_panel_set_label
  (get-ffi-obj "shim_group_panel_set_label" shim-lib
               (_fun _pointer _string/utf-8 -> _void)))

; ---- bell -----------------------------------------------------------------

(define shim_bell
  (get-ffi-obj "shim_bell" shim-lib
               (_fun -> _void)))

; ---- clipboard --------------------------------------------------------
; mode: 0 = QClipboard::Clipboard, 1 = QClipboard::Selection (X11 PRIMARY).
; Same three functions serve both the-clipboard and the-x-selection.

(define shim_clipboard_set_text
  (get-ffi-obj "shim_clipboard_set_text" shim-lib
               (_fun _string/utf-8 _int -> _void)))
(define shim_clipboard_get_text
  (get-ffi-obj "shim_clipboard_get_text" shim-lib
               (_fun _int -> _string/utf-8)))
(define shim_clipboard_has_text
  (get-ffi-obj "shim_clipboard_has_text" shim-lib
               (_fun _int -> _bool)))
(define shim_clipboard_supports_selection
  (get-ffi-obj "shim_clipboard_supports_selection" shim-lib
               (_fun -> _bool)))

; ---- clipboard: bitmap ---------------------------------------------------
; Always QClipboard::Clipboard (no mode parameter -- see shim.cpp comment).

(define shim_clipboard_set_image
  (get-ffi-obj "shim_clipboard_set_image" shim-lib
               (_fun _bytes _int _int -> _void)))
(define shim_clipboard_has_image
  (get-ffi-obj "shim_clipboard_has_image" shim-lib
               (_fun -> _bool)))
(define shim_clipboard_image_size
  (get-ffi-obj "shim_clipboard_image_size" shim-lib
               (_fun (out-w : (_ptr o _int))
                     (out-h : (_ptr o _int))
                     -> (ok : _int)
                     -> (if (zero? ok) (values #f #f) (values out-w out-h)))))
; w/h must be the sizes shim_clipboard_image_size just returned -- the shim
; clamps its copy to them (defends against the clipboard changing between
; the size query and this call; see shim.cpp comment).
(define shim_clipboard_get_image_argb
  (get-ffi-obj "shim_clipboard_get_image_argb" shim-lib
               (_fun _bytes _int _int -> _void)))

; ---- control font -------------------------------------------------------

(define shim_control_font_face
  (get-ffi-obj "shim_control_font_face" shim-lib
               (_fun -> _string/utf-8)))
(define shim_control_font_size
  (get-ffi-obj "shim_control_font_size" shim-lib
               (_fun (out-is-pixels : (_ptr o _int))
                     -> (size : _int)
                     -> (values size (not (zero? out-is-pixels))))))

; ---- double-click time ----------------------------------------------------

(define shim_double_click_time
  (get-ffi-obj "shim_double_click_time" shim-lib
               (_fun -> _int)))

; ---- cursor -------------------------------------------------------------

(define shim_cursor_create_standard
  (get-ffi-obj "shim_cursor_create_standard" shim-lib
               (_fun _string/utf-8 -> _pointer)))
(define shim_cursor_create_from_argb
  (get-ffi-obj "shim_cursor_create_from_argb" shim-lib
               (_fun _bytes _int _int _int _int -> _pointer)))
(define shim_widget_set_cursor
  (get-ffi-obj "shim_widget_set_cursor" shim-lib
               (_fun _pointer _pointer -> _void)))
(define shim_widget_unset_cursor
  (get-ffi-obj "shim_widget_unset_cursor" shim-lib
               (_fun _pointer -> _void)))

; ---- input state (get-current-mouse-state) --------------------------------

(define shim_get_mouse_state
  (get-ffi-obj "shim_get_mouse_state" shim-lib
               (_fun (out-x : (_ptr o _int)) (out-y : (_ptr o _int)) (out-flags : (_ptr o _int))
                     -> _void
                     -> (values out-x out-y out-flags))))

; ---- X11 raw-window support (register-collecting-blit / wx/qt/gcwin.rkt) --
; Nullable: #f (C NULL) when Qt isn't running the xcb platform plugin (e.g.
; Wayland) -- gcwin.rkt's x11-gc-available? treats that as "unsupported
; here", not an error.
(define shim_get_x11_display
  (get-ffi-obj "shim_get_x11_display" shim-lib
               (_fun -> _pointer)))

; QWidget::winId() -- the X11 Window XID directly (no gdk_x11_window_get_xid
; -style lookup needed on this platform).
(define shim_widget_get_x11_window
  (get-ffi-obj "shim_widget_get_x11_window" shim-lib
               (_fun _pointer -> _ulong)))
