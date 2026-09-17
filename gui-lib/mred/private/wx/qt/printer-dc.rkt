#lang racket/base
; Qt printer-dc% / show-print-setup -- File > Print / Page Setup.
;
; Qt6 removed QPrinter::getDC() and there is no public bridge from a cairo_t*
; into QPainter, so this can't reuse win32's cairo_win32_printing_surface_
; create(HDC) or gtk's native GtkPrintOperation cairo context (both real
; vector output). Instead each recorded page is replayed into a plain ARGB32
; cairo image surface (fixed RASTER-DPI) and the raw premultiplied buffer is
; handed to the shim, which wraps it in a QImage and stretches it to fill the
; printer's page via QPainter::drawImage -- text and vector art come out
; rasterized on this backend only (win32/gtk stay vector).
;
; QPrintDialog/QPageSetupDialog run non-modally (open() + finished), exactly
; like filedialog.rkt's QFileDialog -- QDialog::exec() opens a nested
; QEventLoop, which CLAUDE.md Regel 1 forbids regardless of whether Qt's
; native platform dialog is used underneath. The Racket call is made
; synchronous the same way file-selector is: yield on a semaphore until the
; shim's atomic callback (posted as a real event) resolves it. Callback
; trampoline follows filedialog.rkt's established rule (docs/HACKING.md §19):
; ONE persistent native callback built at module load, dispatched by integer
; id through `ud' -- a fresh trampoline per call crashed reproducibly there.
(require racket/class
         ffi/unsafe
         racket/draw/private/dc
         racket/draw/private/local
         racket/draw/private/record-dc
         racket/draw/private/bitmap-dc
         racket/draw/private/bitmap
         racket/draw/private/ps-setup
         racket/draw/unsafe/cairo
         "../../lock.rkt"
         "../common/queue.rkt"
         "window.rkt"
         "utils.rkt")

(provide printer-dc%
         show-print-setup
         can-show-print-setup?)

(define (can-show-print-setup?) #t)

; Fixed rasterization resolution -- see file banner: no vector path exists
; on this backend, unlike win32/gtk. 300dpi keeps a full-page buffer under
; ~35MB (A4 @ ARGB32) while still reading cleanly on a real printer.
(define RASTER-DPI 300)
(define (pt->px n) (max 1 (inexact->exact (round (* n (/ RASTER-DPI 72.0))))))

; ---- single, permanent native callback (mirrors filedialog.rkt §19) -------

(define pending (make-hasheqv))
(define next-id 0)

(define (dispatch-printer-dialog-result ud accepted)
  ; Atomic (Racket CS callbacks always are) -- only the non-blocking hash
  ; lookup + queue-event, no I/O, same discipline as every other callback
  ; in this backend.
  (define id (cast ud _pointer _intptr))
  (define on-result (hash-ref pending id #f))
  (hash-remove! pending id)
  (when on-result (on-result (positive? accepted))))

(define printer-dialog-cb
  (function-ptr dispatch-printer-dialog-result _printer_dialog_cb_t))

; show! : printer-ptr parent-handle cb ud -> void, i.e. one of
; shim_printer_show_print_dialog / shim_printer_show_page_setup_dialog.
; Returns #t if the dialog was accepted, #f on cancel.
(define (run-printer-dialog show! printer-ptr parent-window)
  (define parent-handle (and parent-window (send parent-window get-qt-handle)))
  (define eventspace
    (if parent-window (send parent-window get-eventspace) (current-eventspace)))
  (define result-box (box #f))
  (define done-sema (make-semaphore 0))
  (define (on-result accepted?)
    (queue-event eventspace
                 (lambda ()
                   ; Runs later, on the ordinary (non-atomic) event loop --
                   ; safe to touch result-box/semaphore here.
                   (set-box! result-box accepted?)
                   (when parent-handle (shim_widget_set_enabled parent-handle 1))
                   (semaphore-post done-sema))))
  (define id next-id)
  (set! next-id (add1 next-id))
  (hash-set! pending id on-result)
  (when parent-handle (shim_widget_set_enabled parent-handle 0))
  (show! printer-ptr parent-handle printer-dialog-cb (cast id _intptr _pointer))
  (yield (semaphore-peek-evt done-sema))
  ; Same Crash-B precaution as filedialog.rkt (docs/HACKING.md §39): the C
  ; side already queued dlg->deleteLater() from inside `finished' -- one more
  ; explicit pump guarantees it runs now, not at process-exit time.
  (atomically (shim_pump 0))
  (unbox result-box))

; ---- paper-name <-> Qt QPageSize::PageSizeId --------------------------
; 1=A4 2=A3 3=Letter 4=Legal, matching ps-setup.rkt's paper-sizes order --
; the only four strings its paper-name-string? contract accepts, so a Qt-
; side id of 0 ("unrecognized") can only arise if the user picked some other
; paper in the OS dialog; we then simply leave paper-name as it was.
(define (paper-name->id name)
  (cond [(equal? name (car (list-ref paper-sizes 0))) 1]
        [(equal? name (car (list-ref paper-sizes 1))) 2]
        [(equal? name (car (list-ref paper-sizes 2))) 3]
        [(equal? name (car (list-ref paper-sizes 3))) 4]
        [else 1]))

(define (id->paper-name id)
  (cond [(= id 1) (car (list-ref paper-sizes 0))]
        [(= id 2) (car (list-ref paper-sizes 1))]
        [(= id 3) (car (list-ref paper-sizes 2))]
        [(= id 4) (car (list-ref paper-sizes 3))]
        [else #f]))

(define (apply-ps-setup-to-printer! printer-ptr)
  (define pss (current-ps-setup))
  (shim_printer_set_page_setup printer-ptr
                               (paper-name->id (send pss get-paper-name))
                               (if (eq? (send pss get-orientation) 'landscape) 1 0)))

(define (read-printer-into-ps-setup! printer-ptr)
  (define-values (id landscape) (shim_printer_get_page_setup printer-ptr))
  (define pss (current-ps-setup))
  (send pss set-orientation (if (zero? landscape) 'portrait 'landscape))
  (define name (id->paper-name id))
  (when name (send pss set-paper-name name)))

; parent: a wx-level frame%/dialog% or #f (gdi.rkt's mred-level printer-dc%
; already resolved this before calling super-new).
(define (show-print-setup parent)
  (define printer-ptr (shim_printer_create))
  (apply-ps-setup-to-printer! printer-ptr)
  (define accepted? (run-printer-dialog shim_printer_show_page_setup_dialog
                                        printer-ptr parent))
  (when accepted? (read-printer-into-ps-setup! printer-ptr))
  (shim_printer_destroy printer-ptr)
  accepted?)

; ---- printer-dc% --------------------------------------------------------

(define printer-dc%
  (class (record-dc-mixin (dc-mixin bitmap-dc-backend%))
    (init [parent #f])

    (define parent-frame parent)

    ; A generic, platform-independent cairo-backed bitmap%
    ; (racket/draw/private/bitmap) -- exactly what gtk's printer-dc% uses as
    ; its throwaway target; no qt-specific bitmap class needed here.
    (super-make-object (make-object bitmap% 1 1))

    (inherit get-recorded-command
             reset-recording)

    (define pages null)
    (define/override (end-page)
      (set! pages (cons (get-recorded-command) pages))
      (reset-recording))

    ; Page geometry comes straight from ps-setup's own orientation/paper-name
    ; fields (points, via paper-sizes) instead of a native ps-setup object --
    ; Qt has no equivalent PAGESETUPDLG-style struct to round-trip through,
    ; and this is exactly the geometry `show-print-setup' above already
    ; keeps in sync with whatever the user picked in QPageSetupDialog.
    (define-values (page-width page-height)
      (let* ([pss (current-ps-setup)]
             [entry (assoc (send pss get-paper-name) paper-sizes)]
             [w (if entry (cadr entry) 612)]
             [h (if entry (caddr entry) 792)])
        (if (eq? (send pss get-orientation) 'landscape)
            (values h w)
            (values w h))))

    (define/override (get-size) (values page-width page-height))

    (define/override (end-doc)
      (define printer-ptr (shim_printer_create))
      (apply-ps-setup-to-printer! printer-ptr)
      ; Test-only escape hatch: examples/printer-probe.rkt sets this to a
      ; file path to get a durable, inspectable PDF without a real click on
      ; QPrintDialog (which the production path always shows -- see
      ; run-printer-dialog above).
      (define pdf-path (getenv "PLT_QT_PRINT_TO_PDF"))
      (define accepted?
        (if (and pdf-path (positive? (string-length pdf-path)))
            (begin (shim_printer_set_output_pdf printer-ptr pdf-path) #t)
            (run-printer-dialog shim_printer_show_print_dialog
                                printer-ptr parent-frame)))
      (cond
        [(not accepted?) (shim_printer_destroy printer-ptr)]
        [else
         (define painter-ptr (shim_printer_begin_job printer-ptr "Racket"))
         (cond
           [(not painter-ptr) (shim_printer_destroy printer-ptr)]
           [else
            (define px-w (pt->px page-width))
            (define px-h (pt->px page-height))
            (for ([proc (in-list (reverse pages))]
                  [page-no (in-naturals)])
              (unless (zero? page-no) (shim_printer_new_page printer-ptr))
              (define surface (cairo_image_surface_create CAIRO_FORMAT_ARGB32 px-w px-h))
              (define cr (cairo_create surface))
              (proc
               (make-object
                (class (dc-mixin default-dc-backend%)
                  (super-new)
                  (define/override (init-cr-matrix cr2)
                    (cairo_scale cr2 (/ RASTER-DPI 72.0) (/ RASTER-DPI 72.0)))
                  (define/override (get-cr) cr))))
              (cairo_surface_flush surface)
              (shim_printer_draw_page printer-ptr painter-ptr
                                      (cairo_image_surface_get_data surface)
                                      px-w px-h
                                      (cairo_image_surface_get_stride surface))
              (cairo_destroy cr)
              (cairo_surface_destroy surface))
            (shim_printer_end_job painter-ptr)
            (shim_printer_destroy printer-ptr)])])
      (void))))
