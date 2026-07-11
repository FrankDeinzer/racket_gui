#lang racket/base
; Qt file-selector (get-file / put-file). QFileDialog is run non-modally via
; open() + the finished signal -- no QFileDialog::exec(), no nested
; QEventLoop, same pump invariant as everywhere else in this backend. The
; Racket call is made synchronous the same way dialog%'s modal show is
; (../common/dialog.rkt): yield on a semaphore until the shim's atomic
; callback (queued as a real event) posts it. Parent is disabled via
; setEnabled while the dialog is open, reusing the modal-dialog mechanism
; from frame%'s modal-enable (docs/HACKING.md §18.3/§19).
(require racket/class
         racket/string
         ffi/unsafe
         "../common/queue.rkt"
         "window.rkt"
         "utils.rkt")

(provide file-selector)

; ---- single, permanent native callback -------------------------------------
; Every other widget in this backend creates its click/toggle/etc. callback
; closure ONCE, in the widget's constructor, and the same native trampoline
; is reused for every subsequent event. file-selector has no persistent
; widget object to hang a callback off, but creating a FRESH `_fun`-wrapped
; Racket closure on every single get-file/put-file call turned out not to be
; safe here: it crashed reproducibly on the 3rd dialog in a row (measured,
; docs/HACKING.md §19). Fix: create exactly one native callback at module
; load and dispatch through it, keyed by a small integer id passed through
; as the `ud' void* itself (the standard C userdata idiom) -- never allocate
; a new trampoline per call.
(define pending (make-hasheqv))
(define next-id 0)

(define (dispatch-file-dialog-result ud path-ptr)
  ; Atomic (Racket CS callbacks always are -- foreign_procedures.html,
  ; "Callbacks are always atomic"); atomic-mode code must not perform
  ; blocking I/O, so no eprintf here -- only the minimal, non-blocking hash
  ; lookup + queue-event, mirroring every other callback in this backend.
  (define id (cast ud _pointer _intptr))
  (define on-result (hash-ref pending id #f))
  (hash-remove! pending id)
  (when on-result (on-result path-ptr)))

(define file-dialog-cb
  (function-ptr dispatch-file-dialog-result _file_dialog_cb_t))

(define (path-or-string->utf8-string p)
  (cond [(not p) ""]
        [(path? p) (path->string p)]
        [else p]))

; filters: (listof (list string? string?)), e.g. '(("Any" "*.*")).
; -> Qt name-filter string: "Any (*.*);;Racket (*.rkt *.rktl)"
; (win32-style ";"-separated patterns within one entry become space-separated,
; Qt's own filter-clause separator).
(define (qt-filter-string filters)
  (if (or (not filters) (null? filters))
      ""
      (string-join
       (for/list ([f (in-list filters)])
         (format "~a (~a)" (car f) (regexp-replace* #rx";" (cadr f) " ")))
       ";;")))

(define (file-selector message directory filename extension filters style parent)
  (cond
    ; get-directory / get-file-list: not wired to the Qt path this session
    ; (docs/2026-07-11_prompt.md scope is get-file + put-file only).
    [(or (memq 'dir style) (memq 'multi style)) #f]
    [else
     (define put? (and (memq 'put style) #t))
     (define parent-window
       (and parent (object? parent) (is-a? parent window%) parent))
     (define parent-handle (and parent-window (send parent-window get-qt-handle)))
     (define eventspace
       (if parent-window (send parent-window get-eventspace) (current-eventspace)))
     (define result-box (box #f))
     (define done-sema (make-semaphore 0))
     (define debug? (getenv "PLT_QT_DEBUG"))
     (define (dbg fmt . args)
       (when debug?
         (apply eprintf fmt args)
         (flush-output (current-error-port))))
     (define (on-result path-ptr)
       ; Called from dispatch-file-dialog-result, still in atomic mode --
       ; only the non-blocking cast + queue-event, no I/O.
       (define path (and path-ptr (cast path-ptr _pointer _string/utf-8)))
       (queue-event eventspace
                    (lambda ()
                      ; This thunk runs later, dispatched by the ordinary
                      ; (non-atomic) event loop -- safe to do I/O here.
                      (dbg "[qt-filedialog] queued thunk: running, path=~a\n" path)
                      (set-box! result-box (and path (string->path path)))
                      (when parent-handle (shim_widget_set_enabled parent-handle 1))
                      (semaphore-post done-sema)
                      (dbg "[qt-filedialog] queued thunk: done\n"))))
     (define id next-id)
     (set! next-id (add1 next-id))
     (hash-set! pending id on-result)
     (when parent-handle (shim_widget_set_enabled parent-handle 0))
     (dbg "[qt-filedialog] calling shim_file_dialog_create id=~a\n" id)
     (shim_file_dialog_create parent-handle
                               (if put? 1 0)
                               (or message "")
                               (path-or-string->utf8-string directory)
                               (path-or-string->utf8-string filename)
                               (or extension "")
                               (qt-filter-string filters)
                               file-dialog-cb
                               (cast id _intptr _pointer))
     (dbg "[qt-filedialog] shim_file_dialog_create returned, yielding\n")
     (yield (semaphore-peek-evt done-sema))
     (dbg "[qt-filedialog] yield returned, result=~a\n" (unbox result-box))
     (unbox result-box)]))
