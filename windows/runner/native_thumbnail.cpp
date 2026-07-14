#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <wincodec.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

#include <webp/encode.h>

extern "C" __declspec(dllexport) int BestViewerCreateThumbnail(
    const wchar_t* input_path,
    int target_pixel_count,
    float quality,
    uint8_t** output_bytes,
    size_t* output_size,
    int* output_width,
    int* output_height) {
  if (input_path == nullptr || target_pixel_count <= 0 || output_bytes == nullptr ||
      output_size == nullptr || output_width == nullptr || output_height == nullptr) {
    return E_INVALIDARG;
  }

  *output_bytes = nullptr;
  *output_size = 0;
  const HRESULT init_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool should_uninitialize = SUCCEEDED(init_result);
  IWICImagingFactory* factory = nullptr;
  IWICBitmapDecoder* decoder = nullptr;
  IWICBitmapFrameDecode* frame = nullptr;
  IWICBitmapScaler* scaler = nullptr;
  IWICFormatConverter* converter = nullptr;
  HRESULT result = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                    CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  if (SUCCEEDED(result)) {
    result = factory->CreateDecoderFromFilename(input_path, nullptr, GENERIC_READ,
                                                WICDecodeMetadataCacheOnDemand, &decoder);
  }
  if (SUCCEEDED(result)) result = decoder->GetFrame(0, &frame);

  UINT source_width = 0;
  UINT source_height = 0;
  if (SUCCEEDED(result)) result = frame->GetSize(&source_width, &source_height);
  if (SUCCEEDED(result) && (source_width == 0 || source_height == 0)) result = E_FAIL;

  UINT width = 0;
  UINT height = 0;
  if (SUCCEEDED(result)) {
    const uint64_t source_pixels =
        static_cast<uint64_t>(source_width) * source_height;
    const double scale = source_pixels <= static_cast<uint64_t>(target_pixel_count)
        ? 1.0
        : std::sqrt(static_cast<double>(target_pixel_count) / source_pixels);
    width = std::max(1u, static_cast<UINT>(std::lround(source_width * scale)));
    height = std::max(1u, static_cast<UINT>(std::lround(source_height * scale)));
    result = factory->CreateBitmapScaler(&scaler);
  }
  if (SUCCEEDED(result)) {
    result = scaler->Initialize(frame, width, height, WICBitmapInterpolationModeFant);
  }
  if (SUCCEEDED(result)) result = factory->CreateFormatConverter(&converter);
  if (SUCCEEDED(result)) {
    result = converter->Initialize(scaler, GUID_WICPixelFormat32bppBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeCustom);
  }

  if (SUCCEEDED(result)) {
    const UINT stride = width * 4;
    std::vector<uint8_t> pixels(static_cast<size_t>(stride) * height);
    result = converter->CopyPixels(nullptr, stride,
                                   static_cast<UINT>(pixels.size()), pixels.data());
    if (SUCCEEDED(result)) {
      uint8_t* encoded = nullptr;
      const size_t encoded_size = WebPEncodeBGRA(pixels.data(), static_cast<int>(width),
                                                  static_cast<int>(height), stride, quality,
                                                  &encoded);
      if (encoded_size == 0 || encoded == nullptr) {
        result = E_FAIL;
      } else {
        *output_bytes = encoded;
        *output_size = encoded_size;
        *output_width = static_cast<int>(width);
        *output_height = static_cast<int>(height);
      }
    }
  }

  if (converter) converter->Release();
  if (scaler) scaler->Release();
  if (frame) frame->Release();
  if (decoder) decoder->Release();
  if (factory) factory->Release();
  if (should_uninitialize) CoUninitialize();
  return result;
}

extern "C" __declspec(dllexport) void BestViewerFreeThumbnail(uint8_t* bytes) {
  if (bytes != nullptr) WebPFree(bytes);
}
