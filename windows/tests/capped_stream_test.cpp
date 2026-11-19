#include "../runner/capped_stream.h"
#include <iostream>
#include <limits>

#define CHECK(x) do { if (!(x)) { std::cerr << "Failed at line " << __LINE__ << '\n'; return 1; } } while (false)

int main() {
  auto* stream = new CappedStream(4);
  ULONG written = 0;
  const unsigned char input[] = {1, 2, 3, 4, 5};
  LARGE_INTEGER initial_seek{};
  initial_seek.QuadPart = 4;
  CHECK(stream->Seek(initial_seek, STREAM_SEEK_SET, nullptr) == S_OK);
  written = 99;
  CHECK(stream->Write(input, 0, &written) == S_OK && written == 0);
  CHECK(stream->bytes().empty());
  initial_seek.QuadPart = 0;
  CHECK(stream->Seek(initial_seek, STREAM_SEEK_SET, nullptr) == S_OK);
  CHECK(stream->Write(input, 4, &written) == S_OK && written == 4);
  CHECK(stream->Write(input, 1, &written) == STG_E_MEDIUMFULL && written == 0);
  CHECK(stream->bytes().size() == 4);
  LARGE_INTEGER move{};
  move.QuadPart = -2;
  CHECK(stream->Seek(move, STREAM_SEEK_END, nullptr) == S_OK);
  CHECK(stream->Write(input, 2, &written) == S_OK && written == 2);
  CHECK(stream->bytes()[2] == 1 && stream->bytes()[3] == 2);
  move.QuadPart = (std::numeric_limits<LONGLONG>::min)();
  CHECK(FAILED(stream->Seek(move, STREAM_SEEK_CUR, nullptr)));
  move.QuadPart = 5;
  CHECK(stream->Seek(move, STREAM_SEEK_SET, nullptr) == S_OK);
  CHECK(stream->Write(input, 1, &written) == STG_E_MEDIUMFULL && written == 0);
  CHECK(stream->bytes().size() == 4);
  move.QuadPart = -1;
  CHECK(stream->Seek(move, STREAM_SEEK_SET, nullptr) == S_OK);
  move.QuadPart = 1;
  CHECK(FAILED(stream->Seek(move, STREAM_SEEK_CUR, nullptr)));
  ULARGE_INTEGER size{};
  size.QuadPart = 5;
  CHECK(stream->SetSize(size) == STG_E_MEDIUMFULL);
  size.QuadPart = 2;
  CHECK(stream->SetSize(size) == S_OK && stream->bytes().size() == 2);
  move.QuadPart = 0;
  CHECK(stream->Seek(move, STREAM_SEEK_SET, nullptr) == S_OK);
  unsigned char output[4]{};
  ULONG read = 0;
  CHECK(stream->Read(output, 4, &read) == S_FALSE && read == 2);
  CHECK(output[0] == 1 && output[1] == 2);
  const auto* original = stream->bytes().data();
  auto taken = stream->TakeBytes();
  CHECK(taken.data() == original && taken.size() == 2);
  CHECK(stream->Release() == 0);
  return 0;
}
