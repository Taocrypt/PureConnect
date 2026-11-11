#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#include <cstring>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // The one window. A second launch (the application is unique on D-Bus)
  // activates this instance, which presents it instead of opening another.
  GtkWindow* window;
  FlMethodChannel* window_channel;
  // Launched at login with --hidden: stay in the tray after the first frame.
  gboolean start_hidden;
  // Set by Dart once it handles "close" (hide to tray, or clean up + quit).
  gboolean prevent_close;
  // Immersive frame (FlClash's window plugin, MIT): the caption is drawn by
  // the app, which starts window moves from its drag area.
  FlView* view;
  GtkWidget* event_box;
  GdkEventButton last_press;
  gboolean dragging;
  gulong press_hook_id;
  gboolean maximized;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void notify_dart(MyApplication* self, const gchar* method) {
  if (self->window_channel != nullptr) {
    fl_method_channel_invoke_method(self->window_channel, method, nullptr,
                                    nullptr, nullptr, nullptr);
  }
}

static void present_window(MyApplication* self) {
  self->start_hidden = FALSE;
  if (self->window == nullptr) return;
  gtk_widget_show(GTK_WIDGET(self->window));
  gtk_window_deiconify(self->window);
  gtk_window_present(self->window);
}

static gboolean quit_idle_cb(gpointer user_data) {
  g_application_quit(G_APPLICATION(user_data));
  return G_SOURCE_REMOVE;
}

// Window moves from the app's drag area, as FlClash's window_drag.cc: the
// button press is consumed by Flutter's view before any per-window handler,
// so a global emission hook keeps the last one for begin_move_drag.
static gboolean on_button_press_hook(GSignalInvocationHint*, guint,
                                     const GValue* param_values,
                                     gpointer data) {
  MyApplication* self = MY_APPLICATION(data);
  GObject* emitter = G_OBJECT(g_value_get_object(param_values + 0));
  if (self->view == nullptr ||
      (emitter != G_OBJECT(self->view) && emitter != G_OBJECT(self->event_box))) {
    return TRUE;
  }
  GdkEventButton* event =
      static_cast<GdkEventButton*>(g_value_get_boxed(param_values + 1));
  memcpy(&self->last_press, event, sizeof(self->last_press));
  return TRUE;
}

static void collect_child(GtkWidget* widget, gpointer data) {
  GList** children = static_cast<GList**>(data);
  *children = g_list_prepend(*children, widget);
}

static void find_event_box(MyApplication* self) {
  if (self->view == nullptr) return;
  GList* children = nullptr;
  gtk_container_forall(GTK_CONTAINER(self->view), collect_child, &children);
  for (GList* l = children; l != nullptr; l = l->next) {
    if (GTK_IS_EVENT_BOX(l->data)) self->event_box = GTK_WIDGET(l->data);
  }
  g_list_free(children);
}

// The window manager swallows the release that ends a move; Flutter still
// waits for it, so one is sent when the pointer comes back.
static void emit_button_release(MyApplication* self) {
  if (self->event_box == nullptr) return;
  GdkWindow* window = gtk_widget_get_window(self->event_box);
  if (window == nullptr) return;
  GdkEventButton* event =
      reinterpret_cast<GdkEventButton*>(gdk_event_new(GDK_BUTTON_RELEASE));
  event->window = GDK_WINDOW(g_object_ref(window));
  event->send_event = TRUE;
  event->x = self->last_press.x;
  event->y = self->last_press.y;
  event->button = self->last_press.button;
  event->time = self->last_press.time;
  gboolean handled;
  g_signal_emit_by_name(self->event_box, "button-release-event", event, &handled);
  gdk_event_free(reinterpret_cast<GdkEvent*>(event));
}

static gboolean event_after_cb(GtkWidget*, GdkEvent* event, gpointer data) {
  MyApplication* self = MY_APPLICATION(data);
  if (event->type == GDK_ENTER_NOTIFY && self->dragging) {
    self->dragging = FALSE;
    emit_button_release(self);
  }
  return FALSE;
}

static void start_dragging(MyApplication* self) {
  GtkWindow* window = self->window;
  if (window == nullptr) return;
  if (self->event_box == nullptr) find_event_box(self);
  GdkDisplay* display = gdk_screen_get_display(gtk_window_get_screen(window));
  GdkDevice* device = gdk_seat_get_pointer(gdk_display_get_default_seat(display));
  gint root_x, root_y;
  gdk_device_get_position(device, nullptr, &root_x, &root_y);
  gtk_window_begin_move_drag(window, GDK_BUTTON_PRIMARY, root_x, root_y,
                             self->last_press.time);
  self->dragging = TRUE;
}

// "pureconnect/window": setIcon(<absolute png path>) swaps the window/taskbar
// icon at runtime (menu entries come from the .desktop file, see Dart side);
// show / hide / isVisible / setPreventClose / quit drive the tray behaviour.
static void window_method_cb(FlMethodChannel* channel, FlMethodCall* call,
                             gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  GtkWindow* window = self->window;
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlValue) result = nullptr;
  if (g_strcmp0(method, "setIcon") == 0) {
    gboolean ok = FALSE;
    if (window != nullptr && args != nullptr &&
        fl_value_get_type(args) == FL_VALUE_TYPE_STRING) {
      g_autoptr(GError) error = nullptr;
      ok = gtk_window_set_icon_from_file(window, fl_value_get_string(args),
                                         &error);
      if (ok) {
        gtk_window_set_default_icon_from_file(fl_value_get_string(args),
                                              nullptr);
      }
    }
    result = fl_value_new_bool(ok);
  } else if (g_strcmp0(method, "show") == 0) {
    present_window(self);
    result = fl_value_new_bool(TRUE);
  } else if (g_strcmp0(method, "hide") == 0) {
    if (window != nullptr) gtk_widget_hide(GTK_WIDGET(window));
    result = fl_value_new_bool(TRUE);
  } else if (g_strcmp0(method, "isVisible") == 0) {
    result = fl_value_new_bool(window != nullptr &&
                               gtk_widget_get_visible(GTK_WIDGET(window)));
  } else if (g_strcmp0(method, "setPreventClose") == 0) {
    self->prevent_close = args != nullptr &&
                          fl_value_get_type(args) == FL_VALUE_TYPE_BOOL &&
                          fl_value_get_bool(args);
    result = fl_value_new_bool(TRUE);
  } else if (g_strcmp0(method, "minimize") == 0) {
    if (window != nullptr) gtk_window_iconify(window);
    result = fl_value_new_bool(TRUE);
  } else if (g_strcmp0(method, "maximize") == 0) {
    if (window != nullptr) gtk_window_maximize(window);
    result = fl_value_new_bool(TRUE);
  } else if (g_strcmp0(method, "unmaximize") == 0) {
    if (window != nullptr) gtk_window_unmaximize(window);
    result = fl_value_new_bool(TRUE);
  } else if (g_strcmp0(method, "isMaximized") == 0) {
    result = fl_value_new_bool(window != nullptr && gtk_window_is_maximized(window));
  } else if (g_strcmp0(method, "startDragging") == 0) {
    start_dragging(self);
    result = fl_value_new_bool(TRUE);
  } else if (g_strcmp0(method, "setAlwaysOnTop") == 0) {
    gboolean on = args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL &&
                  fl_value_get_bool(args);
    if (window != nullptr) gtk_window_set_keep_above(window, on);
    result = fl_value_new_bool(TRUE);
  } else if (g_strcmp0(method, "isAlwaysOnTop") == 0) {
    GdkWindow* gdk_window = window == nullptr ? nullptr : gtk_widget_get_window(GTK_WIDGET(window));
    result = fl_value_new_bool(
        gdk_window != nullptr &&
        (gdk_window_get_state(gdk_window) & GDK_WINDOW_STATE_ABOVE) != 0);
  } else if (g_strcmp0(method, "quit") == 0) {
    self->prevent_close = FALSE;
    // Not from inside the engine's callback: quit on the next idle.
    g_idle_add(quit_idle_cb, self);
    result = fl_value_new_bool(TRUE);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  fl_method_call_respond_success(call, result, nullptr);
}

static gboolean delete_event_cb(GtkWidget* widget, GdkEvent* event,
                                gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (!self->prevent_close) return FALSE;
  notify_dart(self, "close");
  return TRUE;
}

// Minimised: Dart hides the window to the tray when "minimise to tray" is on.
static gboolean window_state_cb(GtkWidget* widget, GdkEventWindowState* event,
                                gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if ((event->changed_mask & GDK_WINDOW_STATE_ICONIFIED) &&
      (event->new_window_state & GDK_WINDOW_STATE_ICONIFIED)) {
    notify_dart(self, "minimized");
  }
  if (event->changed_mask & GDK_WINDOW_STATE_MAXIMIZED) {
    // The app's maximize / restore caption button follows the window.
    gboolean maximized = (event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) != 0;
    if (maximized != self->maximized) {
      self->maximized = maximized;
      notify_dart(self, maximized ? "maximized" : "unmaximized");
    }
  }
  return FALSE;
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  if (self->start_hidden) return;
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window != nullptr) {
    // Another launch: show this instance's window.
    present_window(self);
    notify_dart(self, "activate");
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;
  g_signal_connect(window, "delete-event", G_CALLBACK(delete_event_cb), self);
  g_signal_connect(window, "window-state-event", G_CALLBACK(window_state_cb),
                   self);

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  // Immersive frame, as FlClash: the app draws its own caption. With a
  // header bar (GNOME / Wayland) it is created for client-side decorations
  // (shadow, resize edges) and hidden; a traditional title bar is removed.
  gtk_window_set_title(window, "PureConnect");
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_header_bar_set_title(header_bar, "PureConnect");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
    gtk_widget_set_visible(GTK_WIDGET(header_bar), FALSE);
  } else {
    gtk_window_set_decorated(window, FALSE);
  }
  GdkGeometry geometry;
  geometry.min_width = 380;
  geometry.min_height = 400;
  gtk_window_set_geometry_hints(window, nullptr, &geometry, GDK_HINT_MIN_SIZE);
  g_signal_connect(window, "event-after", G_CALLBACK(event_after_cb), self);

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));
  self->view = view;
  self->press_hook_id = g_signal_add_emission_hook(
      g_signal_lookup("button-press-event", GTK_TYPE_WIDGET), 0,
      on_button_press_hook, self, nullptr);

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "pureconnect/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(window_channel, window_method_cb,
                                            self, nullptr);
  self->window_channel = window_channel;

  gtk_widget_grab_focus(GTK_WIDGET(view));
  find_event_box(self);
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);
  for (gchar** arg = *arguments + 1; *arg != nullptr; arg++) {
    if (g_strcmp0(*arg, "--hidden") == 0) self->start_hidden = TRUE;
  }

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  if (self->press_hook_id != 0) {
    g_signal_remove_emission_hook(
        g_signal_lookup("button-press-event", GTK_TYPE_WIDGET), self->press_hook_id);
    self->press_hook_id = 0;
  }
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->window_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     static_cast<GApplicationFlags>(0),
                                     nullptr));
}
