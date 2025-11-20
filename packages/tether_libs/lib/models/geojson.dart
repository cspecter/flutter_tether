import 'dart:math' as math;
import 'dart:typed_data';

import 'package:intl/intl.dart';

/// Converts degrees to radians.
double degToRadian(final double deg) => deg * (math.pi / 180.0);

/// Converts radians to degrees.
double radianToDeg(final double rad) => rad * (180.0 / math.pi);

/// Converts a decimal value to a sexagesimal string (degrees, minutes, seconds).
String decimal2sexagesimal(double dec) {
  final bool isNegative = dec < 0;
  dec = dec.abs();

  final int d = dec.floor();
  dec = (dec - d) * 60;
  final int m = dec.floor();
  dec = (dec - m) * 60;
  final double s = dec;

  final String sStr = NumberFormat("00.00").format(s);
  final String mStr = NumberFormat("00").format(m);
  final String dStr = NumberFormat("00").format(d);

  return "${isNegative ? "-" : ""}$dStr° $mStr' $sStr\"";
}

/// Converts a sexagesimal string (degrees, minutes, seconds) to a decimal value.
double sexagesimal2decimal(String sexagesimal) {
  sexagesimal = sexagesimal.trim();
  final parts = sexagesimal
      .split(RegExp(r"""[°'"\s]+"""))
      .where((s) => s.isNotEmpty)
      .toList();
  if (parts.length < 3) {
    throw FormatException("Invalid sexagesimal format: $sexagesimal");
  }
  final d = double.parse(parts[0]);
  final m = double.parse(parts[1]);
  final s = double.parse(parts[2]);

  final dec = d + (m / 60.0) + (s / 3600.0);

  return dec;
}

/// Represents a geographical point with latitude and longitude.
class LatLng {
  final double latitude;
  final double longitude;

  const LatLng(this.latitude, this.longitude);

  /// Latitude in radians.
  double get latitudeInRad => degToRadian(latitude);

  /// Longitude in radians.
  double get longitudeInRad => degToRadian(longitude);

  /// Creates a LatLng from a JSON map in the format `{'coordinates': [longitude, latitude]}`.
  LatLng.fromJson(Map<String, dynamic> json)
      : latitude = json['coordinates'][1] as double,
        longitude = json['coordinates'][0] as double;

  /// Creates a LatLng from a list of doubles `[longitude, latitude]`.
  factory LatLng.fromList(List<dynamic> list) {
    if (list.length != 2) {
      throw ArgumentError('List must contain exactly two values');
    }
    return LatLng(
      (list[1] as num).toDouble(), // <-- CHANGE THIS
      (list[0] as num).toDouble(), // <-- CHANGE THIS
    );
  }

  /// Converts the LatLng to a JSON map in the format `{'coordinates': [longitude, latitude]}`.
  Map<String, dynamic> toJson() => {
        'coordinates': [longitude, latitude]
      };

  /// Converts the LatLng to a list of doubles `[longitude, latitude]`.
  List<double> toList() {
    return [longitude, latitude];
  }

  /// Converts sexagesimal string into a lat/long value
  ///
  ///     final LatLng p1 = new LatLng.fromSexagesimal('''51° 31' 10.11" N, 19° 22' 32.00" W''');
  ///     print("${p1.latitude}, ${p1.longitude}");
  ///     // Shows:
  ///     51.519475, -19.37555556
  ///
  factory LatLng.fromSexagesimal(final String str) {
    double latitude = 0.0;
    double longitude = 0.0;
    // try format '''47° 09' 53.57" N, 8° 32' 09.04" E'''
    var splits = str.split(',');
    if (splits.length != 2) {
      // try format '''N 47°08'52.57" E 8°32'09.04"'''
      splits = str.split('E');
      if (splits.length != 2) {
        // try format '''N 47°08'52.57" W 8°32'09.04"'''
        splits = str.split('W');
        if (splits.length != 2) {
          throw 'Unsupported sexagesimal format: $str';
        }
      }
    }
    latitude = sexagesimal2decimal(splits[0]);
    longitude = sexagesimal2decimal(splits[1]);
    if (str.contains('S')) {
      latitude = -latitude;
    }
    if (str.contains('W')) {
      longitude = -longitude;
    }
    return LatLng(latitude, longitude);
  }

  /// Converts lat/long values into sexagesimal
  ///
  ///     final LatLng p1 = new LatLng(51.519475, -19.37555556);
  ///
  ///     // Shows: 51° 31' 10.11" N, 19° 22' 32.00" W
  ///     print(p1..toSexagesimal());
  ///
  String toSexagesimal() {
    var latDirection = latitude >= 0 ? 'N' : 'S';
    var lonDirection = longitude >= 0 ? 'E' : 'W';
    return '${decimal2sexagesimal(latitude)} $latDirection, ${decimal2sexagesimal(longitude)} $lonDirection';
  }

  /// Rounds the latitude and longitude to a specified number of decimal places.
  LatLng round({final int decimals = 6}) => LatLng(
      _round(latitude, decimals: decimals),
      _round(longitude, decimals: decimals));

  //- private -----------------------------------------------------------------------------------

  /// No qualifier for top level functions in Dart. Had to copy this function
  double _round(final double value, {final int decimals = 6}) =>
      (value * math.pow(10, decimals)).round() / math.pow(10, decimals);

  @override
  String toString() =>
      'LatLng(latitude:${NumberFormat("0.0#####").format(latitude)}, '
      'longitude:${NumberFormat("0.0#####").format(longitude)})';

  @override
  int get hashCode => latitude.hashCode + longitude.hashCode;

  @override
  bool operator ==(final Object other) =>
      other is LatLng &&
      latitude == other.latitude &&
      longitude == other.longitude;
}

/// Represents a GeoJSON object, commonly used for PostGIS `geometry` types.
class GeoJson {
  /// The type of geometry (e.g., "Point").
  final String type;

  /// The coordinates of the geometry.
  final LatLng coordinates;

  GeoJson({required this.type, required this.coordinates});

  /// Creates a GeoJson object from a JSON map.
  factory GeoJson.fromJson(Map<String, dynamic> json) {
    return GeoJson(
      type: json['type'] as String,
      coordinates: LatLng.fromList(json['coordinates'] as List<dynamic>),
    );
  }

  factory GeoJson.fromWKB(String wkbString) {
    // Parse the WKB string to create a LatLng object
    final latLng = parseWKBPoint(wkbString);
    return GeoJson(
      type: 'Point', // Assuming WKB is for a Point type
      coordinates: latLng,
    );
  }

  /// Converts the GeoJson object to a JSON map.
  Map<String, dynamic> toJson() {
    return {
      'type': type,
      'coordinates': coordinates.toList(),
    };
  }

  String toWKB() {
    // Convert LatLng to WKB (Well-Known Binary) format
    return latLngToWKBPoint(coordinates);
  }

  @override
  String toString() => 'GeoJson(type: $type, coordinates: $coordinates)';
}

LatLng parseWKBPoint(String wkbString) {
  // Convert the hex string to bytes
  final bytes = Uint8List.fromList(
    List<int>.generate(
      wkbString.length ~/ 2,
      (index) => int.parse(
        wkbString.substring(index * 2, index * 2 + 2),
        radix: 16,
      ),
    ),
  );

  final byteData = bytes.buffer.asByteData();

  // Assuming little endian byte order
  final isLittleEndian = byteData.getUint8(0) == 1;

  // Skip the first 5 bytes (1 for byte order, 4 for type indicator)
  final lon = byteData.getFloat64(
    5,
    isLittleEndian ? Endian.little : Endian.big,
  );
  final lat = byteData.getFloat64(
    13,
    isLittleEndian ? Endian.little : Endian.big,
  );

  return LatLng(lat, lon);
}

String latLngToWKBPoint(LatLng latLng) {
  final bytes = BytesBuilder();

  // 1 byte: byte order (1 = little endian)
  bytes.addByte(1);

  // 4 bytes: type (1 = Point)
  bytes.add(Uint8List(4)..buffer.asByteData().setUint32(0, 1, Endian.little));

  // 8 bytes: X (longitude)
  bytes.add(Uint8List(8)
    ..buffer.asByteData().setFloat64(0, latLng.longitude, Endian.little));

  // 8 bytes: Y (latitude)
  bytes.add(Uint8List(8)
    ..buffer.asByteData().setFloat64(0, latLng.latitude, Endian.little));

  // Convert to hex string
  return bytes.toBytes().map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}