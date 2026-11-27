/*
 * rvpn_filter_ui — GTK4 interface for managing Radmin VPN packet filter rules.
 *
 * Escreve $RVPN_FILTER_FILE a cada alteração (adicionar/remover/alternar).
 * tap_bridge verifica este arquivo e aplica os filtros em ~1s. Esta UI não
 * executa comandos nem toca no firewall do host.
 *
 * Compilação: gcc -Wall -O2 -o cc_filter_ui rvpn_filter_ui.c $(pkg-config --cflags --libs gtk4)
 */

#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>


/* Path of the state file, from $RVPN_FILTER_FILE (the launcher scripts put it in
 * a private directory). No fallback: a fixed /tmp path could be planted by
 * another local user. */
static const char *filter_path(void)
{
    const char *p = getenv("RVPN_FILTER_FILE");
    return (p && *p) ? p : NULL;
}
#define MAX_ENTRIES 256

/* ── Estado do aplicativo ── */

typedef struct {
    char *entries[MAX_ENTRIES];
    int   count;
    int   enabled;
} filter_section_t;

typedef struct {
    filter_section_t block_ips;
    filter_section_t block_macs;
    filter_section_t block_broadcast;
    GtkListBox      *ip_list;
    GtkListBox      *mac_list;
    GtkListBox      *bcast_list;
    GtkSwitch       *ip_switch;
    GtkSwitch       *mac_switch;
    GtkSwitch       *bcast_switch;
    GtkEntry        *ip_entry;
    GtkEntry        *mac_entry;
    GtkEntry        *bcast_entry;
} app_state_t;

static app_state_t app;

/* ── Entrada/Saída JSON ── */

static void write_json(void)
{
    const char *path = filter_path();
    if (!path) return;
    char tmp[4096];
    if (snprintf(tmp, sizeof(tmp), "%s.tmp", path) >= (int)sizeof(tmp)) return;
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600);
    FILE *f = fd >= 0 ? fdopen(fd, "w") : NULL;
    if (!f) { perror("write_json"); if (fd >= 0) close(fd); return; }

    fprintf(f, "{\n");
    fprintf(f, "  \"block_ips_enabled\": %s,\n", app.block_ips.enabled ? "true" : "false");
    fprintf(f, "  \"blocked_ips\": [");
    for (int i = 0; i < app.block_ips.count; i++) {
        if (i > 0) fprintf(f, ", ");
        fprintf(f, "\"%s\"", app.block_ips.entries[i]);
    }
    fprintf(f, "],\n");

    fprintf(f, "  \"block_macs_enabled\": %s,\n", app.block_macs.enabled ? "true" : "false");
    fprintf(f, "  \"blocked_macs\": [");
    for (int i = 0; i < app.block_macs.count; i++) {
        if (i > 0) fprintf(f, ", ");
        fprintf(f, "\"%s\"", app.block_macs.entries[i]);
    }
    fprintf(f, "],\n");

    fprintf(f, "  \"block_broadcast_enabled\": %s,\n", app.block_broadcast.enabled ? "true" : "false");
    fprintf(f, "  \"broadcast_block_ips\": [");
    for (int i = 0; i < app.block_broadcast.count; i++) {
        if (i > 0) fprintf(f, ", ");
        fprintf(f, "\"%s\"", app.block_broadcast.entries[i]);
    }
    fprintf(f, "]\n");

    fprintf(f, "}\n");
    fclose(f);
    rename(tmp, path);
}

/* Analisador JSON mínimo (mesma abordagem que tap_bridge) */
static const char *json_find_key(const char *json, const char *key)
{
    char needle[64];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *p = strstr(json, needle);
    if (!p) return NULL;
    p += strlen(needle);
    while (*p == ' ' || *p == '\t' || *p == ':' || *p == '\n' || *p == '\r') p++;
    return p;
}

static int json_bool(const char *json, const char *key, int defval)
{
    const char *p = json_find_key(json, key);
    if (!p) return defval;
    if (strncmp(p, "true", 4) == 0) return 1;
    if (strncmp(p, "false", 5) == 0) return 0;
    return defval;
}

static int json_str_array(const char *json, const char *key,
                          char **out, int max_out)
{
    const char *p = json_find_key(json, key);
    if (!p || *p != '[') return 0;
    p++;
    int count = 0;
    while (count < max_out) {
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == ',') p++;
        if (*p == ']' || *p == '\0') break;
        if (*p != '"') { p++; continue; }
        p++;
        const char *start = p;
        while (*p && *p != '"') p++;
        int len = (int)(p - start);
        out[count] = g_strndup(start, len);
        if (*p == '"') p++;
        count++;
    }
    return count;
}

/* Entries go into hand-written JSON that tap_bridge parses, so accept only what
 * tap_bridge itself understands: dotted IPv4 and aa:bb:cc:dd:ee:ff. */
static int valid_ip(const char *s)
{
    struct in_addr a;
    return inet_pton(AF_INET, s, &a) == 1;
}

static int valid_mac(const char *s)
{
    unsigned m[6];
    char tail;
    return sscanf(s, "%2x:%2x:%2x:%2x:%2x:%2x%c",
                  &m[0], &m[1], &m[2], &m[3], &m[4], &m[5], &tail) == 6
           && strlen(s) == 17;
}

static int valid_entry(const filter_section_t *s, const char *v)
{
    return s == &app.block_macs ? valid_mac(v) : valid_ip(v);
}

/* Drop entries read from disk that fail validation. */
static void prune_invalid(filter_section_t *s)
{
    int n = 0;
    for (int i = 0; i < s->count; i++) {
        if (valid_entry(s, s->entries[i])) {
            s->entries[n++] = s->entries[i];
        } else {
            g_free(s->entries[i]);
        }
    }
    for (int i = n; i < s->count; i++) s->entries[i] = NULL;
    s->count = n;
}

static void load_json(void)
{
    const char *path = filter_path();
    if (!path) return;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != getuid()) {
        close(fd);
        return;
    }
    FILE *f = fdopen(fd, "r");
    if (!f) { close(fd); return; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0 || sz > 65536) { fclose(f); return; }
    char *buf = malloc((size_t)sz + 1);
    if (!buf) { fclose(f); return; }
    size_t rd = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    buf[rd] = '\0';

    app.block_ips.enabled       = json_bool(buf, "block_ips_enabled", 0);
    app.block_macs.enabled      = json_bool(buf, "block_macs_enabled", 0);
    app.block_broadcast.enabled = json_bool(buf, "block_broadcast_enabled", 0);

    app.block_ips.count       = json_str_array(buf, "blocked_ips",
                                    app.block_ips.entries, MAX_ENTRIES);
    app.block_macs.count      = json_str_array(buf, "blocked_macs",
                                    app.block_macs.entries, MAX_ENTRIES);
    app.block_broadcast.count = json_str_array(buf, "broadcast_block_ips",
                                    app.block_broadcast.entries, MAX_ENTRIES);
    free(buf);

    prune_invalid(&app.block_ips);
    prune_invalid(&app.block_macs);
    prune_invalid(&app.block_broadcast);
}

/* ── Gerenciamento de listas ── */

static void free_section(filter_section_t *s)
{
    for (int i = 0; i < s->count; i++) {
        g_free(s->entries[i]);
        s->entries[i] = NULL;
    }
    s->count = 0;
}

static int add_entry(filter_section_t *s, const char *val)
{
    if (s->count >= MAX_ENTRIES) return 0;
    /* evitar duplicatas */
    for (int i = 0; i < s->count; i++) {
        if (strcmp(s->entries[i], val) == 0) return 0;
    }
    s->entries[s->count++] = g_strdup(val);
    return 1;
}

static void remove_entry(filter_section_t *s, int idx)
{
    if (idx < 0 || idx >= s->count) return;
    g_free(s->entries[idx]);
    for (int i = idx; i < s->count - 1; i++)
        s->entries[i] = s->entries[i + 1];
    s->entries[--s->count] = NULL;
}

/* ── Auxiliares de interface ── */

typedef struct {
    filter_section_t *section;
    int               index;
    GtkListBox       *listbox;
} row_data_t;

/* Declaração antecipada */
static void refresh_list(GtkListBox *lb, filter_section_t *s);

static void on_remove_row(GtkButton *btn, gpointer user_data)
{
    row_data_t *rd = user_data;
    int idx = rd->index;
    GtkListBox *lb = rd->listbox;
    filter_section_t *s = rd->section;
    remove_entry(s, idx);
    write_json();
    refresh_list(lb, s);
}

static void refresh_list(GtkListBox *lb, filter_section_t *s)
{
    /* Remove todos os filhos */
    GtkWidget *child = gtk_widget_get_first_child(GTK_WIDGET(lb));
    while (child) {
        GtkWidget *next = gtk_widget_get_next_sibling(child);
        gtk_list_box_remove(lb, child);
        child = next;
    }

    for (int i = 0; i < s->count; i++) {
        GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
        gtk_widget_set_margin_start(row, 8);
        gtk_widget_set_margin_end(row, 8);
        gtk_widget_set_margin_top(row, 4);
        gtk_widget_set_margin_bottom(row, 4);

        GtkWidget *label = gtk_label_new(s->entries[i]);
        gtk_widget_set_hexpand(label, TRUE);
        gtk_widget_set_halign(label, GTK_ALIGN_START);
        gtk_box_append(GTK_BOX(row), label);

        GtkWidget *btn = gtk_button_new_with_label("✕");
        gtk_widget_add_css_class(btn, "destructive-action");
        gtk_button_set_has_frame(GTK_BUTTON(btn), FALSE);

        row_data_t *rd = g_new0(row_data_t, 1);
        rd->section = s;
        rd->index = i;
        rd->listbox = lb;
        g_signal_connect_data(btn, "clicked", G_CALLBACK(on_remove_row),
                              rd, (GClosureNotify)g_free, 0);

        gtk_box_append(GTK_BOX(row), btn);
        gtk_list_box_append(lb, row);
    }
}

static void on_add_clicked(GtkButton *btn, gpointer user_data)
{
    GtkEntry *entry;
    filter_section_t *section;
    GtkListBox *listbox;

    if (user_data == &app.block_ips) {
        entry = app.ip_entry;
        section = &app.block_ips;
        listbox = app.ip_list;
    } else if (user_data == &app.block_macs) {
        entry = app.mac_entry;
        section = &app.block_macs;
        listbox = app.mac_list;
    } else {
        entry = app.bcast_entry;
        section = &app.block_broadcast;
        listbox = app.bcast_list;
    }

    const char *text = gtk_editable_get_text(GTK_EDITABLE(entry));
    if (!text || !*text) return;
    if (!valid_entry(section, text)) {
        fprintf(stderr, "rvpn_filter_ui: rejected invalid %s \"%.64s\" (expected %s)\n",
                section == &app.block_macs ? "MAC" : "IP", text,
                section == &app.block_macs ? "aa:bb:cc:dd:ee:ff" : "a.b.c.d, each 0-255");
        gtk_widget_add_css_class(GTK_WIDGET(entry), "error");
        return;
    }

    gtk_widget_remove_css_class(GTK_WIDGET(entry), "error");
    if (add_entry(section, text)) {
        gtk_editable_set_text(GTK_EDITABLE(entry), "");
        write_json();
        refresh_list(listbox, section);
    }
}

static void on_entry_changed(GtkEditable *e, gpointer user_data)
{
    (void)user_data;
    gtk_widget_remove_css_class(GTK_WIDGET(e), "error");
}

static void on_entry_activate(GtkEntry *entry, gpointer user_data)
{
    on_add_clicked(NULL, user_data);
}

static void on_switch_toggled(GtkSwitch *sw, GParamSpec *pspec, gpointer user_data)
{
    filter_section_t *s = user_data;
    s->enabled = gtk_switch_get_active(sw);
    write_json();
}

/* ── Constrói um cartão de seção de filtro ── */

static GtkWidget *make_section(const char *title,
                               const char *placeholder,
                               filter_section_t *section,
                               GtkSwitch **out_switch,
                               GtkEntry **out_entry,
                               GtkListBox **out_list)
{
    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(card, 12);
    gtk_widget_set_margin_end(card, 12);
    gtk_widget_set_margin_top(card, 12);
    gtk_widget_set_margin_bottom(card, 12);

    /* Linha de título com interruptor */
    GtkWidget *title_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *lbl = gtk_label_new(title);
    gtk_widget_set_hexpand(lbl, TRUE);
    gtk_widget_set_halign(lbl, GTK_ALIGN_START);
    g_object_set(lbl, "margin-start", 0, NULL);
    PangoAttrList *attrs = pango_attr_list_new();
    pango_attr_list_insert(attrs, pango_attr_weight_new(PANGO_WEIGHT_BOLD));
    pango_attr_list_insert(attrs, pango_attr_scale_new(1.1));
    gtk_label_set_attributes(GTK_LABEL(lbl), attrs);
    pango_attr_list_unref(attrs);
    gtk_box_append(GTK_BOX(title_row), lbl);

    GtkSwitch *sw = GTK_SWITCH(gtk_switch_new());
    gtk_switch_set_active(sw, section->enabled);
    g_signal_connect(sw, "notify::active", G_CALLBACK(on_switch_toggled), section);
    gtk_box_append(GTK_BOX(title_row), GTK_WIDGET(sw));
    gtk_box_append(GTK_BOX(card), title_row);

    /* Linha de entrada */
    GtkWidget *entry_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    GtkEntry *ent = GTK_ENTRY(gtk_entry_new());
    gtk_entry_set_placeholder_text(ent, placeholder);
    gtk_widget_set_hexpand(GTK_WIDGET(ent), TRUE);
    g_signal_connect(ent, "activate", G_CALLBACK(on_entry_activate), section);
    g_signal_connect(ent, "changed", G_CALLBACK(on_entry_changed), NULL);
    gtk_box_append(GTK_BOX(entry_row), GTK_WIDGET(ent));

    GtkWidget *add_btn = gtk_button_new_with_label("Add");
    g_signal_connect(add_btn, "clicked", G_CALLBACK(on_add_clicked), section);
    gtk_box_append(GTK_BOX(entry_row), add_btn);
    gtk_box_append(GTK_BOX(card), entry_row);

    /* Lista */
    GtkListBox *lb = GTK_LIST_BOX(gtk_list_box_new());
    gtk_widget_add_css_class(GTK_WIDGET(lb), "rich-list");
    gtk_list_box_set_selection_mode(lb, GTK_SELECTION_NONE);
    gtk_box_append(GTK_BOX(card), GTK_WIDGET(lb));

    *out_switch = sw;
    *out_entry = ent;
    *out_list = lb;

    /* Preencher */
    refresh_list(lb, section);

    return card;
}

/* ── Principal ── */

static void on_activate(GtkApplication *gtk_app, gpointer user_data)
{
    (void)user_data;

    /* Carrega configuração existente */
    load_json();

    GtkWidget *window = gtk_application_window_new(gtk_app);
    gtk_window_set_title(GTK_WINDOW(window), "Radmin VPN — Packet Filters");
    gtk_window_set_default_size(GTK_WINDOW(window), 480, 520);

    /* Contêiner principal */
    GtkWidget *scrolled = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scrolled, TRUE);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);

    GtkWidget *vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_widget_set_margin_start(vbox, 8);
    gtk_widget_set_margin_end(vbox, 8);
    gtk_widget_set_margin_top(vbox, 8);
    gtk_widget_set_margin_bottom(vbox, 8);

    /* Seção 1: Bloquear IPs */
    GtkWidget *ip_card = make_section("Block IP Addresses",
                                      "e.g. 26.1.2.3",
                                      &app.block_ips,
                                      &app.ip_switch, &app.ip_entry, &app.ip_list);
    gtk_box_append(GTK_BOX(vbox), ip_card);

    /* Separador */
    gtk_box_append(GTK_BOX(vbox), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));

    /* Seção 2: Bloquear MACs */
    GtkWidget *mac_card = make_section("Block MAC Addresses",
                                       "e.g. aa:bb:cc:dd:ee:ff",
                                       &app.block_macs,
                                       &app.mac_switch, &app.mac_entry, &app.mac_list);
    gtk_box_append(GTK_BOX(vbox), mac_card);

    /* Separador */
    gtk_box_append(GTK_BOX(vbox), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));

    /* Seção 3: Bloquear Broadcast */
    GtkWidget *bcast_card = make_section("Block Minecraft Broadcast (UDP:4445)",
                                         "e.g. 26.10.20.30",
                                         &app.block_broadcast,
                                         &app.bcast_switch, &app.bcast_entry, &app.bcast_list);
    gtk_box_append(GTK_BOX(vbox), bcast_card);

    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), vbox);
    gtk_window_set_child(GTK_WINDOW(window), scrolled);
    gtk_window_present(GTK_WINDOW(window));

    /* Escreve configuração inicial se o arquivo não existir */
    struct stat st;
    const char *path = filter_path();
    if (path && stat(path, &st) != 0)
        write_json();
}

int main(int argc, char *argv[])
{
    memset(&app, 0, sizeof(app));

    if (!filter_path()) {
        fprintf(stderr, "rvpn_filter_ui: RVPN_FILTER_FILE is not set; start it through run.sh\n");
        return 1;
    }

    GtkApplication *gtk_app = gtk_application_new("org.radminvpn.filterui",
                                                  G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(gtk_app, "activate", G_CALLBACK(on_activate), NULL);

    int ret = g_application_run(G_APPLICATION(gtk_app), argc, argv);
    g_object_unref(gtk_app);

    /* Limpeza */
    free_section(&app.block_ips);
    free_section(&app.block_macs);
    free_section(&app.block_broadcast);

    return ret;
}
