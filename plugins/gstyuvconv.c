/* yuvconv: single-pass BGRx -> NV12 converter backed by libyuv.
 *
 * videoconvert does this conversion in multiple passes over the frame
 * (unpack -> matrix -> chroma subsample -> pack), which costs most of a CPU
 * core at 1080p60. libyuv's ARGBToNV12 (SIMD, one pass) does the same work
 * in a fraction of the time. libyuv names formats by little-endian word
 * order, so its "ARGB" is B,G,R,A in memory — exactly GStreamer's BGRx.
 *
 * libyuv is loaded with dlopen so this plugin has no build-time dependency
 * on libyuv-dev; Ubuntu ships the runtime library (libyuv.so.0).
 *
 * Build (uses the bundled GStreamer's headers):
 *   PKG_CONFIG_PATH=../gstreamer/lib/pkgconfig \
 *   gcc -O2 -shared -fPIC gstyuvconv.c -o libgstyuvconv.so \
 *       $(pkg-config --cflags --libs gstreamer-video-1.0) -ldl
 */
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
} GstYuvConv;

typedef struct
{
  GstVideoFilterClass parent_class;
} GstYuvConvClass;

#define GST_TYPE_YUVCONV (gst_yuvconv_get_type())
GType gst_yuvconv_get_type (void);
G_DEFINE_TYPE (GstYuvConv, gst_yuvconv, GST_TYPE_VIDEO_FILTER);

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

static GstFlowReturn
gst_yuvconv_transform_frame (GstVideoFilter * filter, GstVideoFrame * in,
    GstVideoFrame * out)
{
  if (argb_to_nv12 (GST_VIDEO_FRAME_PLANE_DATA (in, 0),
          GST_VIDEO_FRAME_PLANE_STRIDE (in, 0),
          GST_VIDEO_FRAME_PLANE_DATA (out, 0),
          GST_VIDEO_FRAME_PLANE_STRIDE (out, 0),
          GST_VIDEO_FRAME_PLANE_DATA (out, 1),
          GST_VIDEO_FRAME_PLANE_STRIDE (out, 1),
          GST_VIDEO_FRAME_WIDTH (in), GST_VIDEO_FRAME_HEIGHT (in)) != 0)
    return GST_FLOW_ERROR;
  return GST_FLOW_OK;
}

static void
gst_yuvconv_init (GstYuvConv * self)
{
}

static void
gst_yuvconv_class_init (GstYuvConvClass * klass)
{
  GstElementClass *ec = GST_ELEMENT_CLASS (klass);
  GstBaseTransformClass *bc = GST_BASE_TRANSFORM_CLASS (klass);
  GstVideoFilterClass *vc = GST_VIDEO_FILTER_CLASS (klass);

  gst_element_class_set_static_metadata (ec,
      "libyuv BGRx to NV12 converter", "Filter/Converter/Video",
      "Single-pass SIMD BGRx to NV12 conversion via libyuv",
      "selkies-local");
  gst_element_class_add_static_pad_template (ec, &sink_tmpl);
  gst_element_class_add_static_pad_template (ec, &src_tmpl);
  bc->transform_caps = gst_yuvconv_transform_caps;
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
    "libyuv colorspace converter", plugin_init, "1.0", "LGPL",
    "selkies-local", "https://github.com/selkies-project/selkies")
