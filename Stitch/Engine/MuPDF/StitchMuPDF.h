// The only door between Stitch and MuPDF.
//
// MuPDF reports errors with setjmp/longjmp, which must never jump through Swift code, so every MuPDF
// call lives in StitchMuPDF.c inside fz_try/fz_catch. Each function returns SMU_OK or an error code and
// writes a readable message into `err`. Swift only ever sees this header (no MuPDF types).
//
// Coordinates: "display space" is MuPDF's page space: the page as it is shown (rotation applied), origin
// at the top-left, y pointing down, in points. `smu_page_info` gives the matrix from PDF user space
// (what PDFKit uses) to display space.

#ifndef STITCH_MUPDF_H
#define STITCH_MUPDF_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SMU_OK 0
#define SMU_ERROR 1
#define SMU_NEEDS_PASSWORD 2
#define SMU_NOT_FOUND 3

#define SMU_FONT_BOLD 1
#define SMU_FONT_ITALIC 2
#define SMU_FONT_SERIF 4
#define SMU_FONT_MONO 8

#define SMU_DOC_HAS_XFA 1
#define SMU_DOC_DIGITALLY_SIGNED 2

/// Widget types, the same numbers as MuPDF's PDF_WIDGET_TYPE_*.
#define SMU_FIELD_UNKNOWN 0
#define SMU_FIELD_BUTTON 1
#define SMU_FIELD_CHECKBOX 2
#define SMU_FIELD_COMBOBOX 3
#define SMU_FIELD_LISTBOX 4
#define SMU_FIELD_RADIO 5
#define SMU_FIELD_SIGNATURE 6
#define SMU_FIELD_TEXT 7

typedef struct smu_doc smu_doc;

/// One character of a page's text, in display space.
typedef struct {
    uint32_t c;          // Unicode scalar
    float x0, y0, x1, y1; // the character's box
    float ox, oy;        // origin: the point on the baseline where it starts
    float size;          // font size in points
    uint32_t argb;       // sRGB color, alpha in the top byte
    int32_t block;       // text block (paragraph) number on the page
    int32_t line;        // line number within the page (unique across blocks)
    int32_t font_flags;  // SMU_FONT_*
    char font[64];       // font name as stored in the PDF (may carry a "ABCDEF+" subset prefix)
} smu_char;

typedef struct {
    char name[256];      // fully qualified field name
    int32_t type;        // SMU_FIELD_*
    int32_t page;
    float x0, y0, x1, y1; // display space
    char value[512];
    char on_state[64];   // checkboxes and radio buttons: the "on" value
} smu_field;

/// Opens a PDF. `password` may be NULL. On failure returns NULL and sets `status`
/// (SMU_NEEDS_PASSWORD when a password is missing or wrong).
smu_doc *smu_open(const char *path, const char *password, int *status, char *err, int errlen);
void smu_close(smu_doc *doc);

int smu_page_count(smu_doc *doc);

/// Writes the whole document to `path`, unencrypted, unused objects dropped.
int smu_save(smu_doc *doc, const char *path, char *err, int errlen);

/// `ctm` (6 floats: a b c d e f) maps PDF user space to display space; `size` (2 floats) is the
/// displayed page size; `rotation` is the page's /Rotate in degrees.
int smu_page_info(smu_doc *doc, int page, float *ctm, float *size, int *rotation, char *err, int errlen);

/// Every character on the page. Free `*chars` with `smu_free`.
int smu_page_chars(smu_doc *doc, int page, smu_char **chars, int *count, char *err, int errlen);

/// Removes the text that touches any of the rectangles (display space, 4 floats each: x0 y0 x1 y1).
/// Images and drawings are kept, and nothing is painted over the area.
int smu_remove_text(smu_doc *doc, int page, const float *rects, int rect_count, char *err, int errlen);

/// Draws page 1 of the PDF at `stamp_path` onto `page` as a Form XObject. `matrix` (6 floats) maps the
/// stamp's own coordinates (its media box) to the target page's PDF user space.
int smu_place_pdf(smu_doc *doc, int page, const char *stamp_path, const float *matrix, char *err, int errlen);

/// Every form widget. Free `*fields` with `smu_free`.
int smu_list_fields(smu_doc *doc, smu_field **fields, int *count, char *err, int errlen);

/// Sets a field by its full name. Text and choice fields take the text; checkboxes "Off" or anything
/// else for on; radio buttons the on-state of the button to select ("Off" for none).
/// Returns SMU_NOT_FOUND when no widget has that name.
int smu_set_field(smu_doc *doc, const char *name, const char *value, char *err, int errlen);

/// SMU_DOC_* bits.
int smu_doc_flags(smu_doc *doc);

/// Draws annotations and form fields into the page content so they can no longer be changed.
int smu_bake(smu_doc *doc, char *err, int errlen);

void smu_free(void *ptr);

#ifdef __cplusplus
}
#endif

#endif
