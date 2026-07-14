/* gtk_hello.c — the smallest possible GTK3 native-Wayland client: create a
 * single toplevel GtkWindow and enter the main loop. Used to isolate the
 * "GTK/GDK apps park before get_xdg_surface" hypothesis away from the
 * heavyweight multiprocess browsers (Firefox/WebKitGTK) that stall at the
 * SAME rung. If THIS maps a window, the browsers' stall is heavier than a
 * common GDK-negotiation gap; if it stalls identically, the gap is in the
 * compositor's GDK-facing handshake.
 *
 * Compiled on the host against libgtk-3.so.0 with manual prototypes (no -dev
 * headers needed), the same host-copy staging model as MiniBrowser. */

extern void  gtk_init(int *argc, char ***argv);
extern void *gtk_window_new(int type);            /* GTK_WINDOW_TOPLEVEL = 0 */
extern void  gtk_window_set_title(void *w, const char *t);
extern void  gtk_window_set_default_size(void *w, int width, int height);
extern void *gtk_label_new(const char *str);
extern void  gtk_container_add(void *container, void *child);
extern void  gtk_widget_show_all(void *w);
extern void  gtk_main(void);
extern void  gtk_main_quit(void);
extern unsigned long g_signal_connect_data(void *instance, const char *sig,
        void *handler, void *data, void *destroy, int flags);

extern int   write(int fd, const void *buf, unsigned long n);

static void say(const char *s) {
    unsigned long n = 0; while (s[n]) n++;
    write(2, s, n);
}

static void on_destroy(void *w, void *d) { (void)w; (void)d; gtk_main_quit(); }

int main(int argc, char **argv) {
    say("[GTKHELLO] gtk_init\n");
    gtk_init(&argc, &argv);
    say("[GTKHELLO] gtk_window_new\n");
    void *win = gtk_window_new(0);
    gtk_window_set_title(win, "Hamnix GTK Hello");
    gtk_window_set_default_size(win, 400, 200);
    g_signal_connect_data(win, "destroy", (void *)on_destroy, 0, 0, 0);
    void *lbl = gtk_label_new("GTK3 native Wayland window on Hamnix");
    gtk_container_add(win, lbl);
    say("[GTKHELLO] show_all -> entering gtk_main\n");
    gtk_widget_show_all(win);
    say("[GTKHELLO] gtk_main (mapped if we got here + window is up)\n");
    gtk_main();
    say("[GTKHELLO] gtk_main returned (window closed)\n");
    return 0;
}
