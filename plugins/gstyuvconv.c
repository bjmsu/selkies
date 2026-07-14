/* yuvconv: single-pass BGRx -> NV12 converter backed by libyuv, with
 * duplicate-frame dropping.
 *
 * Conversion: videoconvert does BGRx->NV12 in multiple passes over the frame
 * (unpack -> matrix -> chroma subsample -> pack), which costs most of a CPU
 * core at 1080p60. libyuv's ARGBToNV12 (SIMD, one pass) does the same work
 * in a fraction of the time. libyuv names formats by little-endian word
 * order, so its "ARGB" is B,G,R,A in memory — exactly GStreamer's BGRx.
 *
 * Dedup: ximagesrc pushes at the configured framerate whether or not the
 * screen changed (its use-damage mode is broken: it self-triggers ~30fps on
 * an idle desktop). Comparing each incoming frame against the previous one
 * and returning GST_BASE_TRANSFORM_FLOW_DROPPED for identical frames lets
 * the encoder, payloader and network sleep while the desktop is static.
 * memcmp exits on the first differing byte, so moving content pays almost
 * nothing. A heartbeat frame is let through every 500ms so the WebRTC
 * receiver never mistakes a static desktop for a dead stream, and so the
 * CBR encoder keeps refining a just-changed picture to sharpness quickly
 * (the refinement rate is one step per heartbeat while static).
 *
 * libyuv is loaded with dlopen so this plugin has no build-time dependency
 * on libyuv-dev; Ubuntu ships the runtime library (libyuv.so.0).
 *
 * Build (uses the bundled GStreamer's headers):
 *   PKG_CONFIG_PATH=../gstreamer/lib/pkgconfig \
 *   gcc -O2 -shared -fPIC gstyuvconv.c -o libgstyuvconv.so \
 *       $(pkg-config --define-prefix --cflags --libs gstreamer-video-1.0) -ldl
 */
#include <string.h>

#include <gst/gst.h>
#include <gst/video/video.h>
#include <gst/video/gstvideofilter.h>
#include <dlfcn.h>

typedef int (*ArgbToNv12Fn) (const guint8 * src, int src_stride,
    guint8 * dst_y, int dst_stride_y,
    guint8 * dst_uv, int dst_stride_uv, int width, int height);
static ArgbToNv12Fn argb_to_nv12;

typedef struct
{
  GstVideoFilter parent;

  gboolean dedup;               /* property: drop identical frames */
  guint heartbeat_ms;           /* property: max ms between emitted frames */
  gint force_emit;              /* property (atomic): pass the next frame
                                 * unconditionally, then self-clear. Set by
                                 * the app when the browser PLIs for a
                                 * keyframe, so the IDR is not delayed by up
                                 * to a heartbeat interval (libwebrtc re-PLIs
                                 * after ~200ms, which otherwise snowballs
                                 * into a keyframe storm on a static desktop). */

  guint8 *prev;                 /* previous frame, compact width*4 rows */
  gsize prev_rowbytes;
  gint prev_height;
  gboolean have_prev;
  gint64 last_push_us;          /* monotonic time of last emitted frame */
} GstYuvConv;

typedef struct
{
  GstVideoFilterClass parent_class;
} GstYuvConvClass;

#define GST_TYPE_YUVCONV (gst_yuvconv_get_type())
GType gst_yuvconv_get_type (void);
G_DEFINE_TYPE (GstYuvConv, gst_yuvconv, GST_TYPE_VIDEO_FILTER);

enum
{
  PROP_0,
  PROP_DEDUP,
  PROP_HEARTBEAT_MS,
  PROP_FORCE_EMIT,
};

static GstStaticPadTemplate sink_tmpl = GST_STATIC_PAD_TEMPLATE ("sink",
    GST_PAD_SINK, GST_PAD_ALWAYS,
    GST_STATIC_CAPS (GST_VIDEO_CAPS_MAKE ("BGRx")));

static GstStaticPadTemplate src_tmpl = GST_STATIC_PAD_TEMPLATE ("src",
    GST_PAD_SRC, GST_PAD_ALWAYS,
    GST_STATIC_CAPS (GST_VIDEO_CAPS_MAKE ("NV12")));

static GstCaps *
gst_yuvconv_transform_caps (GstBaseTransform * trans, GstPadDirection dir,
    GstCaps * caps, GstCaps * filter)
{
  GstCaps *ret = gst_caps_copy (caps);
  guint i;

  for (i = 0; i < gst_caps_get_size (ret); i++) {
    GstStructure *s = gst_caps_get_structure (ret, i);
    gst_structure_remove_fields (s, "colorimetry", "chroma-site", NULL);
    if (dir == GST_PAD_SINK) {
      /* libyuv's ARGBToNV12 always applies the BT.601 studio-swing matrix;
       * declaring it here keeps downstream elements from "converting" the
       * default BT.709 assumption to BT.601 in software every frame. */
      gst_structure_set (s, "format", G_TYPE_STRING, "NV12",
          "colorimetry", G_TYPE_STRING, "bt601", NULL);
    } else {
      gst_structure_set (s, "format", G_TYPE_STRING, "BGRx", NULL);
    }
  }
  if (filter) {
    GstCaps *tmp =
        gst_caps_intersect_full (filter, ret, GST_CAPS_INTERSECT_FIRST);
    gst_caps_unref (ret);
    ret = tmp;
  }
  return ret;
}

static gboolean
gst_yuvconv_set_info (GstVideoFilter * filter, GstCaps * incaps,
    GstVideoInfo * in_info, GstCaps * outcaps, GstVideoInfo * out_info)
{
  GstYuvConv *self = (GstYuvConv *) filter;
  gsize rowbytes = (gsize) GST_VIDEO_INFO_WIDTH (in_info) * 4;
  gsize size = rowbytes * GST_VIDEO_INFO_HEIGHT (in_info);

  g_free (self->prev);
  self->prev = g_malloc (size);
  self->prev_rowbytes = rowbytes;
  self->prev_height = GST_VIDEO_INFO_HEIGHT (in_info);
  self->have_prev = FALSE;
  return TRUE;
}

/* Dedup happens here, BEFORE the base class allocates and maps the output
 * buffer: the encoder proposes a VA-backed pool, and mapping those buffers
 * costs real CPU/GPU-sync time that would be wasted on frames we are about
 * to drop anyway. */
static GstFlowReturn
gst_yuvconv_prepare_output_buffer (GstBaseTransform * trans, GstBuffer * inbuf,
    GstBuffer ** outbuf)
{
  GstYuvConv *self = (GstYuvConv *) trans;
  GstVideoFilter *filter = GST_VIDEO_FILTER (trans);

  if (self->dedup && self->prev && filter->negotiated) {
    GstVideoFrame in;

    if (gst_video_frame_map (&in, &filter->in_info, inbuf, GST_MAP_READ)) {
      const guint8 *src = GST_VIDEO_FRAME_PLANE_DATA (&in, 0);
      gint src_stride = GST_VIDEO_FRAME_PLANE_STRIDE (&in, 0);
      gint height = GST_VIDEO_FRAME_HEIGHT (&in);
      gsize rowbytes = (gsize) GST_VIDEO_FRAME_WIDTH (&in) * 4;

      if (height == self->prev_height && rowbytes == self->prev_rowbytes) {
        gint64 now = g_get_monotonic_time ();
        gboolean forced = g_atomic_int_compare_and_exchange (&self->force_emit,
            TRUE, FALSE);

        if (self->have_prev && !forced &&
            now - self->last_push_us < (gint64) self->heartbeat_ms * 1000) {
          gboolean identical = TRUE;
          gint y;

          for (y = 0; y < height; y++) {
            if (memcmp (src + (gsize) y * src_stride,
                    self->prev + (gsize) y * rowbytes, rowbytes) != 0) {
              identical = FALSE;
              break;
            }
          }
          if (identical) {
            gst_video_frame_unmap (&in);
            *outbuf = NULL;
            return GST_BASE_TRANSFORM_FLOW_DROPPED;
          }
        }

        /* frame changed (or heartbeat due): remember it for the next compare */
        if (src_stride == (gint) rowbytes) {
          memcpy (self->prev, src, rowbytes * height);
        } else {
          gint y;
          for (y = 0; y < height; y++)
            memcpy (self->prev + (gsize) y * rowbytes,
                src + (gsize) y * src_stride, rowbytes);
        }
        self->have_prev = TRUE;
        self->last_push_us = now;
      }
      gst_video_frame_unmap (&in);
    }
  }

  return GST_BASE_TRANSFORM_CLASS (gst_yuvconv_parent_class)->
      prepare_output_buffer (trans, inbuf, outbuf);
}

static GstFlowReturn
gst_yuvconv_transform_frame (GstVideoFilter * filter, GstVideoFrame * in,
    GstVideoFrame * out)
{
  gint height = GST_VIDEO_FRAME_HEIGHT (in);

  if (argb_to_nv12 (GST_VIDEO_FRAME_PLANE_DATA (in, 0),
          GST_VIDEO_FRAME_PLANE_STRIDE (in, 0),
          GST_VIDEO_FRAME_PLANE_DATA (out, 0),
          GST_VIDEO_FRAME_PLANE_STRIDE (out, 0),
          GST_VIDEO_FRAME_PLANE_DATA (out, 1),
          GST_VIDEO_FRAME_PLANE_STRIDE (out, 1),
          GST_VIDEO_FRAME_WIDTH (in), height) != 0)
    return GST_FLOW_ERROR;
  return GST_FLOW_OK;
}

static void
gst_yuvconv_set_property (GObject * object, guint prop_id,
    const GValue * value, GParamSpec * pspec)
{
  GstYuvConv *self = (GstYuvConv *) object;

  switch (prop_id) {
    case PROP_DEDUP:
      self->dedup = g_value_get_boolean (value);
      break;
    case PROP_HEARTBEAT_MS:
      self->heartbeat_ms = g_value_get_uint (value);
      break;
    case PROP_FORCE_EMIT:
      g_atomic_int_set (&self->force_emit, g_value_get_boolean (value));
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
  }
}

static void
gst_yuvconv_get_property (GObject * object, guint prop_id, GValue * value,
    GParamSpec * pspec)
{
  GstYuvConv *self = (GstYuvConv *) object;

  switch (prop_id) {
    case PROP_DEDUP:
      g_value_set_boolean (value, self->dedup);
      break;
    case PROP_HEARTBEAT_MS:
      g_value_set_uint (value, self->heartbeat_ms);
      break;
    case PROP_FORCE_EMIT:
      g_value_set_boolean (value, g_atomic_int_get (&self->force_emit));
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
  }
}

static void
gst_yuvconv_finalize (GObject * object)
{
  GstYuvConv *self = (GstYuvConv *) object;

  g_free (self->prev);
  self->prev = NULL;
  G_OBJECT_CLASS (gst_yuvconv_parent_class)->finalize (object);
}

static void
gst_yuvconv_init (GstYuvConv * self)
{
  self->dedup = TRUE;
  /* Below libwebrtc's 200ms keyframe-wait timeout: once the receiver is in
   * keyframe-required state, any inter-frame gap over 200ms times out and
   * re-triggers a PLI, which sustains a keyframe-request storm on a static
   * desktop. Keeping frames flowing faster than that starves the loop. */
  self->heartbeat_ms = 150;
}

static void
gst_yuvconv_class_init (GstYuvConvClass * klass)
{
  GObjectClass *oc = G_OBJECT_CLASS (klass);
  GstElementClass *ec = GST_ELEMENT_CLASS (klass);
  GstBaseTransformClass *bc = GST_BASE_TRANSFORM_CLASS (klass);
  GstVideoFilterClass *vc = GST_VIDEO_FILTER_CLASS (klass);

  oc->set_property = gst_yuvconv_set_property;
  oc->get_property = gst_yuvconv_get_property;
  oc->finalize = gst_yuvconv_finalize;

  g_object_class_install_property (oc, PROP_DEDUP,
      g_param_spec_boolean ("dedup", "Drop duplicate frames",
          "Drop frames identical to the previous one so downstream sleeps "
          "while the picture is static", TRUE,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));
  g_object_class_install_property (oc, PROP_HEARTBEAT_MS,
      g_param_spec_uint ("heartbeat-ms", "Heartbeat interval",
          "Always emit a frame after this many milliseconds even if nothing "
          "changed", 100, 60000, 150,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));
  g_object_class_install_property (oc, PROP_FORCE_EMIT,
      g_param_spec_boolean ("force-emit", "Force emit one frame",
          "Pass the next frame even if identical (self-clears); set this "
          "when downstream needs a keyframe right now", FALSE,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  gst_element_class_set_static_metadata (ec,
      "libyuv BGRx to NV12 converter", "Filter/Converter/Video",
      "Single-pass SIMD BGRx to NV12 conversion via libyuv, "
      "with duplicate-frame dropping", "selkies-local");
  gst_element_class_add_static_pad_template (ec, &sink_tmpl);
  gst_element_class_add_static_pad_template (ec, &src_tmpl);
  bc->transform_caps = gst_yuvconv_transform_caps;
  bc->prepare_output_buffer = gst_yuvconv_prepare_output_buffer;
  vc->set_info = gst_yuvconv_set_info;
  vc->transform_frame = gst_yuvconv_transform_frame;
}

static gboolean
plugin_init (GstPlugin * plugin)
{
  void *handle = dlopen ("libyuv.so.0", RTLD_NOW | RTLD_LOCAL);
  if (!handle)
    return FALSE;
  argb_to_nv12 = (ArgbToNv12Fn) dlsym (handle, "ARGBToNV12");
  if (!argb_to_nv12)
    return FALSE;
  return gst_element_register (plugin, "yuvconv", GST_RANK_NONE,
      GST_TYPE_YUVCONV);
}

#define PACKAGE "selkies-local"
GST_PLUGIN_DEFINE (GST_VERSION_MAJOR, GST_VERSION_MINOR, yuvconv,
    "libyuv colorspace converter", plugin_init, "1.1", "LGPL",
    "selkies-local", "https://github.com/selkies-project/selkies")
