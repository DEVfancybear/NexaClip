# NexaClip

Bộ khung ứng dụng Flutter quản lý clipboard, ưu tiên Windows. Hiện tại chỉ có màn hình khởi đầu; chưa theo dõi hay lưu clipboard.

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

Project được khởi tạo cho Windows bằng Flutter 3.47.9 stable. Lịch sử clipboard và lưu trữ cục bộ sẽ được thực hiện trong các bước tiếp theo.
