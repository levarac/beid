// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sensing_record.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class SensingRecordAdapter extends TypeAdapter<SensingRecord> {
  @override
  final typeId = 1;

  @override
  SensingRecord read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return SensingRecord(
      id: fields[0] as String,
      partnerUuid: fields[1] as String,
      rssi: (fields[2] as num).toInt(),
      detectedAt: fields[3] as DateTime,
      status: fields[4] == null
          ? SensingStatus.detected
          : fields[4] as SensingStatus,
      txHash: fields[5] as String?,
      errorMessage: fields[6] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, SensingRecord obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.partnerUuid)
      ..writeByte(2)
      ..write(obj.rssi)
      ..writeByte(3)
      ..write(obj.detectedAt)
      ..writeByte(4)
      ..write(obj.status)
      ..writeByte(5)
      ..write(obj.txHash)
      ..writeByte(6)
      ..write(obj.errorMessage);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SensingRecordAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class SensingStatusAdapter extends TypeAdapter<SensingStatus> {
  @override
  final typeId = 0;

  @override
  SensingStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return SensingStatus.detected;
      case 1:
        return SensingStatus.pending;
      case 2:
        return SensingStatus.verified;
      case 3:
        return SensingStatus.poapIssued;
      case 4:
        return SensingStatus.failed;
      default:
        return SensingStatus.detected;
    }
  }

  @override
  void write(BinaryWriter writer, SensingStatus obj) {
    switch (obj) {
      case SensingStatus.detected:
        writer.writeByte(0);
      case SensingStatus.pending:
        writer.writeByte(1);
      case SensingStatus.verified:
        writer.writeByte(2);
      case SensingStatus.poapIssued:
        writer.writeByte(3);
      case SensingStatus.failed:
        writer.writeByte(4);
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SensingStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
