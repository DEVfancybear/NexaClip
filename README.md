# NexaClip

Ứng dụng Flutter quản lý clipboard cho Windows. Phiên bản đang phát triển có thể lưu lịch sử văn bản cục bộ khi người dùng bật theo dõi, dừng theo dõi và xóa lịch sử. Các chức năng khác đang được phát triển.

## Thiết lập trên Windows

Cài Flutter SDK theo hướng dẫn chính thức: https://docs.flutter.dev/get-started/install/windows/desktop. Cần thêm Visual Studio với workload **Desktop development with C++** để build ứng dụng Windows.

Từ thư mục này, chạy:

```powershell
flutter doctor -v
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

Project được khởi tạo cho Windows bằng Flutter 3.47.9 stable.

Kiểm thử tích hợp Windows sử dụng clipboard hệ thống thật và sẽ thay nội dung hiện tại bằng dữ liệu thử. Chỉ chạy khi có thể mất nội dung clipboard hiện tại. Không chạy đồng thời với các ứng dụng hoặc kiểm thử khác đang sử dụng clipboard. Cần Python trên Windows; thay đường dẫn sau bằng đường dẫn tới `python.exe`:

```powershell
flutter test integration_test/clipboard_windows_test.dart -d windows --dart-define=TEST_PYTHON=C:\path\to\python.exe
```

Test này dùng cơ sở dữ liệu tạm và chỉ lưu các chuỗi thử được chỉ định. Test không bảo đảm nhận được mọi thông báo clipboard; việc không thấy một mục riêng tư trong cơ sở dữ liệu không chứng minh thông báo của mục đó đã được xử lý.

## Quyền riêng tư và giới hạn

- Lịch sử được lưu cục bộ trong SQLite **không mã hóa** và có thể chứa mật khẩu hoặc dữ liệu nhạy cảm. Theo dõi mặc định tắt khi mở ứng dụng.
- Xóa lịch sử là xóa logic, không đảm bảo xóa an toàn khỏi tệp, bản sao lưu hoặc thiết bị lưu trữ.
- Sao chép lại thay nội dung clipboard hiện tại. Khi đang theo dõi, thay đổi này có thể được lưu thành một mục lịch sử mới trùng nội dung.
- Khi clipboard bị ứng dụng khác giữ hoặc thay đổi quá nhanh, NexaClip có thể bỏ lỡ một số bản sao. Không có cơ chế nào bảo đảm nhận diện mọi dữ liệu nhạy cảm.
- Khi đóng ứng dụng, các bản ghi đang chờ có thể chưa được lưu. Chức năng đóng an toàn đang được hoàn thiện.
- Lịch sử giữ tối đa 500 mục không ghim mới nhất; mục đã ghim không bị loại bởi giới hạn này. Khi bỏ ghim, mục cũ có thể bị loại ngay. Xóa toàn bộ cũng xóa mục đã ghim.
