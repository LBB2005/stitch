// See StitchMuPDF.h. Every MuPDF call in Stitch is in this file, inside fz_try/fz_catch.
// Locals written inside fz_try and read in fz_always/fz_catch are `volatile` (setjmp rules).

#include "StitchMuPDF.h"

#include <mupdf/fitz.h>
#include <mupdf/pdf.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct smu_doc {
    fz_context *ctx;
    pdf_document *pdf;
};

static void set_err(char *err, int errlen, const char *msg) {
    if (err && errlen > 0) snprintf(err, (size_t)errlen, "%s", msg && *msg ? msg : "Unknown PDF error");
}

static int caught(fz_context *ctx, char *err, int errlen) {
    set_err(err, errlen, fz_caught_message(ctx));
    return SMU_ERROR;
}

static void copy_str(char *dst, size_t cap, const char *src) {
    snprintf(dst, cap, "%s", src ? src : "");
}

// MARK: open / save / close

smu_doc *smu_open(const char *path, const char *password, int *status, char *err, int errlen) {
    *status = SMU_ERROR;
    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    if (!ctx) {
        set_err(err, errlen, "Out of memory");
        return NULL;
    }
    pdf_document *volatile pdf = NULL;
    volatile int result = SMU_OK;
    fz_try(ctx) {
        pdf = pdf_open_document(ctx, path);
        if (pdf_needs_password(ctx, pdf)) {
            if (!password || !pdf_authenticate_password(ctx, pdf, password)) {
                result = SMU_NEEDS_PASSWORD;
                set_err(err, errlen, password ? "Wrong password" : "This PDF needs a password");
            }
        }
    }
    fz_catch(ctx) {
        result = caught(ctx, err, errlen);
    }
    if (result != SMU_OK) {
        fz_try(ctx) pdf_drop_document(ctx, pdf);
        fz_catch(ctx) {}
        fz_drop_context(ctx);
        *status = result;
        return NULL;
    }
    smu_doc *doc = calloc(1, sizeof(smu_doc));
    doc->ctx = ctx;
    doc->pdf = pdf;
    *status = SMU_OK;
    return doc;
}

void smu_close(smu_doc *doc) {
    if (!doc) return;
    fz_try(doc->ctx) pdf_drop_document(doc->ctx, doc->pdf);
    fz_catch(doc->ctx) {}
    fz_drop_context(doc->ctx);
    free(doc);
}

int smu_page_count(smu_doc *doc) {
    volatile int n = 0;
    fz_try(doc->ctx) n = pdf_count_pages(doc->ctx, doc->pdf);
    fz_catch(doc->ctx) n = 0;
    return n;
}

int smu_save(smu_doc *doc, const char *path, char *err, int errlen) {
    fz_context *ctx = doc->ctx;
    pdf_write_options opts = pdf_default_write_options;
    opts.do_garbage = 1;
    opts.do_compress = 1;
    opts.do_encrypt = PDF_ENCRYPT_NONE;
    fz_try(ctx) pdf_save_document(ctx, doc->pdf, path, &opts);
    fz_catch(ctx) return caught(ctx, err, errlen);
    return SMU_OK;
}

void smu_free(void *ptr) { free(ptr); }

// MARK: pages

int smu_page_info(smu_doc *doc, int page, float *ctm, float *size, int *rotation, char *err, int errlen) {
    fz_context *ctx = doc->ctx;
    fz_try(ctx) {
        pdf_obj *obj = pdf_lookup_page_obj(ctx, doc->pdf, page);
        fz_rect box;
        fz_matrix m;
        pdf_page_obj_transform(ctx, obj, &box, &m);
        fz_rect shown = fz_transform_rect(box, m);
        ctm[0] = m.a; ctm[1] = m.b; ctm[2] = m.c; ctm[3] = m.d; ctm[4] = m.e; ctm[5] = m.f;
        size[0] = shown.x1 - shown.x0;
        size[1] = shown.y1 - shown.y0;
        *rotation = pdf_dict_get_inheritable_int(ctx, obj, PDF_NAME(Rotate));
    }
    fz_catch(ctx) return caught(ctx, err, errlen);
    return SMU_OK;
}

// MARK: text

typedef struct {
    smu_char *items;
    int count;
    int cap;
    int block;
    int line;
    int failed;
} char_list;

static void push_char(fz_context *ctx, char_list *list, fz_stext_char *ch) {
    if (list->failed) return;
    if (list->count == list->cap) {
        int cap = list->cap ? list->cap * 2 : 512;
        smu_char *grown = realloc(list->items, (size_t)cap * sizeof(smu_char));
        if (!grown) {
            list->failed = 1;
            return;
        }
        list->items = grown;
        list->cap = cap;
    }
    smu_char *out = &list->items[list->count++];
    memset(out, 0, sizeof(*out));
    fz_rect r = fz_rect_from_quad(ch->quad);
    out->c = (uint32_t)ch->c;
    out->x0 = r.x0; out->y0 = r.y0; out->x1 = r.x1; out->y1 = r.y1;
    out->ox = ch->origin.x; out->oy = ch->origin.y;
    out->size = ch->size;
    out->argb = ch->argb;
    out->block = list->block;
    out->line = list->line;
    if (ch->font) {
        copy_str(out->font, sizeof(out->font), fz_font_name(ctx, ch->font));
        if (fz_font_is_bold(ctx, ch->font)) out->font_flags |= SMU_FONT_BOLD;
        if (fz_font_is_italic(ctx, ch->font)) out->font_flags |= SMU_FONT_ITALIC;
        if (fz_font_is_serif(ctx, ch->font)) out->font_flags |= SMU_FONT_SERIF;
        if (fz_font_is_monospaced(ctx, ch->font)) out->font_flags |= SMU_FONT_MONO;
    }
}

static void walk_blocks(fz_context *ctx, fz_stext_block *block, char_list *list) {
    for (; block; block = block->next) {
        if (block->type == FZ_STEXT_BLOCK_STRUCT) {
            if (block->u.s.down) walk_blocks(ctx, block->u.s.down->first_block, list);
        } else if (block->type == FZ_STEXT_BLOCK_TEXT) {
            for (fz_stext_line *line = block->u.t.first_line; line; line = line->next) {
                for (fz_stext_char *ch = line->first_char; ch; ch = ch->next) push_char(ctx, list, ch);
                list->line++;
            }
            list->block++;
        }
    }
}

int smu_page_chars(smu_doc *doc, int page, smu_char **chars, int *count, char *err, int errlen) {
    fz_context *ctx = doc->ctx;
    fz_page *volatile p = NULL;
    fz_stext_page *volatile text = NULL;
    char_list list = {0};
    volatile int result = SMU_OK;
    *chars = NULL;
    *count = 0;
    fz_try(ctx) {
        p = (fz_page *)pdf_load_page(ctx, doc->pdf, page);
        fz_stext_options opts;
        fz_init_stext_options(ctx, &opts);
        text = fz_new_stext_page_from_page(ctx, p, &opts);
        walk_blocks(ctx, text->first_block, &list);
    }
    fz_always(ctx) {
        fz_drop_stext_page(ctx, text);
        fz_drop_page(ctx, p);
    }
    fz_catch(ctx) result = caught(ctx, err, errlen);
    if (result == SMU_OK && list.failed) {
        set_err(err, errlen, "Out of memory");
        result = SMU_ERROR;
    }
    if (result != SMU_OK) {
        free(list.items);
        return result;
    }
    *chars = list.items;
    *count = list.count;
    return SMU_OK;
}

int smu_remove_text(smu_doc *doc, int page, const float *rects, int rect_count, char *err, int errlen) {
    fz_context *ctx = doc->ctx;
    pdf_page *volatile p = NULL;
    fz_try(ctx) {
        p = pdf_load_page(ctx, doc->pdf, page);
        for (int i = 0; i < rect_count; i++) {
            pdf_annot *annot = pdf_create_annot(ctx, p, PDF_ANNOT_REDACT);
            fz_rect r = fz_make_rect(rects[i * 4], rects[i * 4 + 1], rects[i * 4 + 2], rects[i * 4 + 3]);
            pdf_set_annot_rect(ctx, annot, r);
            pdf_drop_annot(ctx, annot);
        }
        pdf_redact_options opts;
        opts.black_boxes = 0;
        opts.image_method = PDF_REDACT_IMAGE_NONE;
        opts.line_art = PDF_REDACT_LINE_ART_NONE;
        opts.text = PDF_REDACT_TEXT_REMOVE;
        pdf_redact_page(ctx, doc->pdf, p, &opts);
    }
    fz_always(ctx) fz_drop_page(ctx, (fz_page *)p);
    fz_catch(ctx) return caught(ctx, err, errlen);
    return SMU_OK;
}

// MARK: stamps

static fz_buffer *page_contents(fz_context *ctx, pdf_obj *page) {
    fz_buffer *buf = fz_new_buffer(ctx, 1024);
    fz_try(ctx) {
        pdf_obj *contents = pdf_dict_get(ctx, page, PDF_NAME(Contents));
        if (pdf_is_array(ctx, contents)) {
            int n = pdf_array_len(ctx, contents);
            for (int i = 0; i < n; i++) {
                fz_buffer *part = pdf_load_stream(ctx, pdf_array_get(ctx, contents, i));
                fz_append_buffer(ctx, buf, part);
                fz_append_byte(ctx, buf, '\n');
                fz_drop_buffer(ctx, part);
            }
        } else if (pdf_is_stream(ctx, contents)) {
            fz_buffer *part = pdf_load_stream(ctx, contents);
            fz_append_buffer(ctx, buf, part);
            fz_drop_buffer(ctx, part);
        }
    }
    fz_catch(ctx) {
        fz_drop_buffer(ctx, buf);
        fz_rethrow(ctx);
    }
    return buf;
}

static fz_buffer *string_buffer(fz_context *ctx, const char *s) {
    fz_buffer *buf = fz_new_buffer(ctx, strlen(s) + 1);
    fz_try(ctx) fz_append_string(ctx, buf, s);
    fz_catch(ctx) {
        fz_drop_buffer(ctx, buf);
        fz_rethrow(ctx);
    }
    return buf;
}

int smu_place_pdf(smu_doc *doc, int page, const char *stamp_path, const float *m, char *err, int errlen) {
    fz_context *ctx = doc->ctx;
    pdf_document *dst = doc->pdf;
    pdf_document *volatile src = NULL;
    pdf_graft_map *volatile map = NULL;
    fz_buffer *volatile content = NULL;
    fz_buffer *volatile head = NULL;
    fz_buffer *volatile tail = NULL;
    pdf_obj *volatile res = NULL;
    pdf_obj *volatile xobj = NULL;
    pdf_obj *volatile head_ref = NULL;
    pdf_obj *volatile tail_ref = NULL;
    pdf_obj *volatile list = NULL;
    fz_try(ctx) {
        src = pdf_open_document(ctx, stamp_path);
        pdf_obj *stamp = pdf_lookup_page_obj(ctx, src, 0);
        fz_rect bbox = pdf_to_rect(ctx, pdf_dict_get_inheritable(ctx, stamp, PDF_NAME(MediaBox)));
        content = page_contents(ctx, stamp);
        map = pdf_new_graft_map(ctx, dst);
        res = pdf_graft_mapped_object(ctx, map, pdf_dict_get_inheritable(ctx, stamp, PDF_NAME(Resources)));
        xobj = pdf_new_xobject(ctx, dst, bbox, fz_identity, res, content);

        pdf_obj *target = pdf_lookup_page_obj(ctx, dst, page);
        pdf_obj *resources = pdf_dict_get(ctx, target, PDF_NAME(Resources));
        if (!resources) {
            pdf_obj *inherited = pdf_dict_get_inheritable(ctx, target, PDF_NAME(Resources));
            resources = inherited ? pdf_copy_dict(ctx, inherited) : pdf_new_dict(ctx, dst, 2);
            pdf_dict_put_drop(ctx, target, PDF_NAME(Resources), resources);
        }
        pdf_obj *xobjects = pdf_dict_get(ctx, resources, PDF_NAME(XObject));
        if (!xobjects) xobjects = pdf_dict_put_dict(ctx, resources, PDF_NAME(XObject), 4);
        char name[32];
        for (int n = 1;; n++) {
            snprintf(name, sizeof(name), "StitchStamp%d", n);
            if (!pdf_dict_gets(ctx, xobjects, name)) break;
        }
        pdf_dict_puts(ctx, xobjects, name, xobj);

        // Existing content is wrapped in q … Q so whatever state it leaves behind can't move the stamp.
        head = string_buffer(ctx, "q\n");
        tail = fz_new_buffer(ctx, 128);
        fz_append_printf(ctx, tail, "\nQ\nq %g %g %g %g %g %g cm /%s Do Q\n", m[0], m[1], m[2], m[3], m[4], m[5], name);
        head_ref = pdf_add_stream(ctx, dst, head, NULL, 0);
        tail_ref = pdf_add_stream(ctx, dst, tail, NULL, 0);
        list = pdf_new_array(ctx, dst, 4);
        pdf_array_push(ctx, list, head_ref);
        pdf_obj *contents = pdf_dict_get(ctx, target, PDF_NAME(Contents));
        if (pdf_is_array(ctx, contents)) {
            int n = pdf_array_len(ctx, contents);
            for (int i = 0; i < n; i++) pdf_array_push(ctx, list, pdf_array_get(ctx, contents, i));
        } else if (contents) {
            pdf_array_push(ctx, list, contents);
        }
        pdf_array_push(ctx, list, tail_ref);
        pdf_dict_put(ctx, target, PDF_NAME(Contents), list);
    }
    fz_always(ctx) {
        pdf_drop_obj(ctx, list);
        pdf_drop_obj(ctx, tail_ref);
        pdf_drop_obj(ctx, head_ref);
        pdf_drop_obj(ctx, xobj);
        pdf_drop_obj(ctx, res);
        fz_drop_buffer(ctx, tail);
        fz_drop_buffer(ctx, head);
        fz_drop_buffer(ctx, content);
        pdf_drop_graft_map(ctx, map);
        pdf_drop_document(ctx, src);
    }
    fz_catch(ctx) return caught(ctx, err, errlen);
    return SMU_OK;
}

// MARK: forms

static int is_on(fz_context *ctx, pdf_obj *widget) {
    const char *as = pdf_dict_get_name(ctx, widget, PDF_NAME(AS));
    return as && *as && strcmp(as, "Off") != 0;
}

int smu_list_fields(smu_doc *doc, smu_field **fields, int *count, char *err, int errlen) {
    fz_context *ctx = doc->ctx;
    smu_field *volatile items = NULL;
    volatile int n = 0;
    volatile int cap = 0;
    pdf_page *volatile p = NULL;
    char *volatile name = NULL;
    *fields = NULL;
    *count = 0;
    fz_try(ctx) {
        int pages = pdf_count_pages(ctx, doc->pdf);
        for (int i = 0; i < pages; i++) {
            p = pdf_load_page(ctx, doc->pdf, i);
            for (pdf_annot *w = pdf_first_widget(ctx, p); w; w = pdf_next_widget(ctx, w)) {
                if (n == cap) {
                    int grown_cap = cap ? cap * 2 : 32;
                    smu_field *grown = realloc(items, (size_t)grown_cap * sizeof(smu_field));
                    if (!grown) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
                    items = grown;
                    cap = grown_cap;
                }
                smu_field *f = &items[n];
                memset(f, 0, sizeof(*f));
                pdf_obj *obj = pdf_annot_obj(ctx, w);
                name = pdf_load_field_name(ctx, obj);
                copy_str(f->name, sizeof(f->name), name);
                fz_free(ctx, name);
                name = NULL;
                f->type = (int32_t)pdf_widget_type(ctx, w);
                f->page = i;
                fz_rect r = pdf_bound_widget(ctx, w);
                f->x0 = r.x0; f->y0 = r.y0; f->x1 = r.x1; f->y1 = r.y1;
                copy_str(f->value, sizeof(f->value), pdf_field_value(ctx, obj));
                if (f->type == SMU_FIELD_CHECKBOX || f->type == SMU_FIELD_RADIO) {
                    copy_str(f->on_state, sizeof(f->on_state), pdf_to_name(ctx, pdf_button_field_on_state(ctx, obj)));
                    if (!is_on(ctx, obj)) copy_str(f->value, sizeof(f->value), "Off");
                }
                n++;
            }
            fz_drop_page(ctx, (fz_page *)p);
            p = NULL;
        }
    }
    fz_always(ctx) {
        fz_free(ctx, name);
        fz_drop_page(ctx, (fz_page *)p);
    }
    fz_catch(ctx) {
        free(items);
        return caught(ctx, err, errlen);
    }
    *fields = items;
    *count = n;
    return SMU_OK;
}

int smu_set_field(smu_doc *doc, const char *name, const char *value, char *err, int errlen) {
    fz_context *ctx = doc->ctx;
    pdf_page *volatile p = NULL;
    char *volatile field_name = NULL;
    volatile int found = 0;
    fz_try(ctx) {
        int pages = pdf_count_pages(ctx, doc->pdf);
        for (int i = 0; i < pages; i++) {
            p = pdf_load_page(ctx, doc->pdf, i);
            int touched = 0;
            for (pdf_annot *w = pdf_first_widget(ctx, p); w; w = pdf_next_widget(ctx, w)) {
                pdf_obj *obj = pdf_annot_obj(ctx, w);
                field_name = pdf_load_field_name(ctx, obj);
                int match = field_name && strcmp(field_name, name) == 0;
                fz_free(ctx, field_name);
                field_name = NULL;
                if (!match) continue;
                found = 1;
                touched = 1;
                switch (pdf_widget_type(ctx, w)) {
                case PDF_WIDGET_TYPE_TEXT:
                    pdf_set_text_field_value(ctx, w, value);
                    break;
                case PDF_WIDGET_TYPE_COMBOBOX:
                case PDF_WIDGET_TYPE_LISTBOX:
                    pdf_set_choice_field_value(ctx, w, value);
                    break;
                case PDF_WIDGET_TYPE_CHECKBOX:
                case PDF_WIDGET_TYPE_RADIOBUTTON: {
                    const char *on = pdf_to_name(ctx, pdf_button_field_on_state(ctx, obj));
                    int want = strcmp(value, "Off") != 0;
                    if (pdf_widget_type(ctx, w) == PDF_WIDGET_TYPE_RADIOBUTTON) want = want && strcmp(value, on) == 0;
                    if (want != is_on(ctx, obj)) pdf_toggle_widget(ctx, w);
                    break;
                }
                default:
                    break;
                }
            }
            if (touched) pdf_update_page(ctx, p);
            fz_drop_page(ctx, (fz_page *)p);
            p = NULL;
        }
    }
    fz_always(ctx) {
        fz_free(ctx, field_name);
        fz_drop_page(ctx, (fz_page *)p);
    }
    fz_catch(ctx) return caught(ctx, err, errlen);
    if (!found) {
        set_err(err, errlen, "No form field with that name");
        return SMU_NOT_FOUND;
    }
    return SMU_OK;
}

int smu_doc_flags(smu_doc *doc) {
    fz_context *ctx = doc->ctx;
    volatile int flags = 0;
    pdf_page *volatile p = NULL;
    fz_try(ctx) {
        if (pdf_dict_getp(ctx, pdf_trailer(ctx, doc->pdf), "Root/AcroForm/XFA")) flags |= SMU_DOC_HAS_XFA;
        if (pdf_count_signatures(ctx, doc->pdf) > 0) {
            int pages = pdf_count_pages(ctx, doc->pdf);
            for (int i = 0; i < pages && !(flags & SMU_DOC_DIGITALLY_SIGNED); i++) {
                p = pdf_load_page(ctx, doc->pdf, i);
                for (pdf_annot *w = pdf_first_widget(ctx, p); w; w = pdf_next_widget(ctx, w)) {
                    if (pdf_widget_type(ctx, w) == PDF_WIDGET_TYPE_SIGNATURE && pdf_widget_is_signed(ctx, w)) {
                        flags |= SMU_DOC_DIGITALLY_SIGNED;
                        break;
                    }
                }
                fz_drop_page(ctx, (fz_page *)p);
                p = NULL;
            }
        }
    }
    fz_always(ctx) fz_drop_page(ctx, (fz_page *)p);
    fz_catch(ctx) {}
    return flags;
}

int smu_bake(smu_doc *doc, char *err, int errlen) {
    fz_context *ctx = doc->ctx;
    fz_try(ctx) pdf_bake_document(ctx, doc->pdf, 1, 1);
    fz_catch(ctx) return caught(ctx, err, errlen);
    return SMU_OK;
}
