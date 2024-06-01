import 'input_stream.dart';

abstract class FileContent {
  List<int> get content;
  InputStreamBase? get rawContent;
}
