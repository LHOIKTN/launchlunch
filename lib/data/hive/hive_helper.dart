import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/food.dart';
import '../../models/meal.dart';
import 'dart:convert';
import 'dart:io'; // 파일 삭제를 위한 임포트

class HiveHelper {
  static final HiveHelper instance = HiveHelper._internal();
  HiveHelper._internal();

  static const String _foodBoxName = 'foods';
  static const String _mealBoxName = 'meals';
  static const String _metadataBoxName = 'metadata';
  static const String _userBoxName = 'user';
  static Box<Food>? _foodBox;
  static Box<DailyMeal>? _mealBox;
  static Box<String>? _metadataBox;
  static Box<String>? _userBox;
  static bool _isInitialized = false;

  Future<void> init() async {
    // 이미 초기화되었으면 중복 초기화 방지
    if (_isInitialized) {
      return;
    }

    try {
      await Hive.initFlutter();

      // 어댑터 등록 (중복 등록 방지)
      if (!Hive.isAdapterRegistered(0)) {
        Hive.registerAdapter(FoodAdapter());
      }
      if (!Hive.isAdapterRegistered(1)) {
        Hive.registerAdapter(DailyMealAdapter());
      }

      // 박스들 열기
      _foodBox = await Hive.openBox<Food>(_foodBoxName);
      _mealBox = await Hive.openBox<DailyMeal>(_mealBoxName);
      _metadataBox = await Hive.openBox<String>(_metadataBoxName);
      _userBox = await Hive.openBox<String>(_userBoxName);

      _isInitialized = true;
    } catch (e) {
      print('❌ Hive 초기화 실패: $e');
      _isInitialized = false;
      rethrow;
    }
  }

  // Metadata management for last updated_at times
  String? getLastUpdatedAt(String tableName) {
    return _metadataBox?.get('last_updated_$tableName');
  }

  Future<void> resetMetadata(String boxName) async {
    await Hive.deleteBoxFromDisk(boxName);
  }

  Future<void> setLastUpdatedAt(String tableName, String updatedAt) async {
    await _metadataBox?.put('last_updated_$tableName', updatedAt);
  }

  String? getUserUUID() {
    return _metadataBox?.get('uuid');
  }

  // Save user info
  Future<void> saveUserInfo(Map<String, dynamic> userInfo) async {
    // UUID 저장 (문자열로 변환)
    if (userInfo['uuid'] != null) {
      await _metadataBox?.put('uuid', userInfo['uuid'].toString());
    }

    // 전체 사용자 정보를 JSON으로 저장
    final userInfoJson = jsonEncode(userInfo);
    await _metadataBox?.put('user_info', userInfoJson);

    print('✅ 사용자 정보 저장 완료: ${userInfo['uuid']}');
  }

  // Get user info
  Map<String, dynamic>? getUserInfo() {
    final userInfoJson = _metadataBox?.get('user_info');
    if (userInfoJson != null) {
      try {
        // JSON을 Map으로 변환
        final userInfo = jsonDecode(userInfoJson) as Map<String, dynamic>;
        return userInfo;
      } catch (e) {
        print('❌ 사용자 정보 파싱 실패: $e');
        return {};
      }
    }
    return {};
  }

  // Get all foods
  List<Food> getAllFoods() {
    return _foodBox?.values.toList() ?? [];
  }

  // Save multiple foods
  Future<void> saveFoods(List<Food> foods) async {
    final Map<int, Food> foodMap = {for (var food in foods) food.id: food};
    await _foodBox?.putAll(foodMap);
  }

  // 개별 음식 데이터 upsert (기존 데이터 유지하면서 업데이트)
  Future<void> upsertFood(Food food) async {
    final existingFood = _foodBox?.get(food.id);

    if (existingFood != null) {
      // 기존 데이터가 있으면 acquiredAt과 recipes는 유지하고 나머지는 업데이트
      final updatedFood = Food(
        id: food.id,
        name: food.name,
        imageUrl: food.imageUrl,
        detail: food.detail,
        acquiredAt: existingFood.acquiredAt, // 기존 획득 상태 유지
        recipes: existingFood.recipes, // 기존 레시피 유지 (별도 동기화에서 처리)
      );
      await _foodBox?.put(food.id, updatedFood);
      print('🔄 음식 ${food.id}(${food.name}) 업데이트 완료');
    } else {
      // 새로운 음식이면 그대로 추가
      await _foodBox?.put(food.id, food);
      print('➕ 음식 ${food.id}(${food.name}) 새로 추가');
    }
  }

  // Update food recipes (완전 교체)
  Future<void> updateFoodRecipes(int foodId, List<int> recipes) async {
    print('🔧 [Hive 업데이트] 음식 $foodId 레시피 최신 데이터로 완전 교체 시작: $recipes');

    final food = _foodBox?.get(foodId);
    if (food != null) {
      print('✅ [Hive 업데이트] 음식 $foodId 찾음: ${food.name}');
      print('📝 [Hive 업데이트] 기존 레시피: ${food.recipes}');
      print('🔄 [Hive 업데이트] 최신 레시피로 완전 교체: $recipes');

      final updatedFood = food.copyWith(recipes: recipes);
      await _foodBox?.put(foodId, updatedFood);

      print(
          '✅ [Hive 업데이트] 음식 $foodId 레시피 최신 데이터로 교체 완료: ${updatedFood.recipes}');

      // 업데이트 후 검증
      final verifyFood = _foodBox?.get(foodId);
      if (verifyFood?.recipes != null) {
        print('🎯 [Hive 검증] 음식 $foodId 최신 데이터 검증 성공: ${verifyFood!.recipes}');
      } else {
        print('❌ [Hive 검증] 음식 $foodId 최신 데이터 검증 실패: 레시피가 null');
      }
    } else {
      print('❌ [Hive 업데이트] 음식 $foodId를 찾을 수 없음!');
    }
  }

  // Update food acquiredAt
  Future<void> updateFoodAcquiredAt(int foodId, DateTime? acquiredAt) async {
    final food = _foodBox?.get(foodId);
    if (food != null) {
      final updatedFood = food.copyWith(acquiredAt: acquiredAt);
      await _foodBox?.put(foodId, updatedFood);
    }
  }

  // Get foods that user has acquired (acquiredAt is not null) - sorted by acquisition date
  List<Food> getAcquiredFoods() {
    final acquiredFoods =
        _foodBox?.values.where((food) => food.acquiredAt != null).toList() ??
            [];

    // 획득일 순으로 정렬 (오래된 획득이 먼저, 최신 획득이 나중에)
    acquiredFoods.sort((a, b) {
      if (a.acquiredAt == null && b.acquiredAt == null) return 0;
      if (a.acquiredAt == null) return 1;
      if (b.acquiredAt == null) return -1;
      return a.acquiredAt!.compareTo(b.acquiredAt!);
    });

    return acquiredFoods;
  }

  // DailyMeal 관련 메서드들

  // 모든 급식 데이터 가져오기
  List<DailyMeal> getAllMeals() {
    return _mealBox?.values.toList() ?? [];
  }

  // 특정 날짜의 급식 데이터 가져오기
  DailyMeal? getMealByDate(String lunchDate) {
    return _mealBox?.get(lunchDate);
  }

  // 급식 데이터 upsert (있으면 업데이트, 없으면 추가)
  Future<void> upsertMeal(DailyMeal meal) async {
    final existingMeal = getMealByDate(meal.lunchDate);
    if (existingMeal != null) {
      print('🔄 급식 데이터 업데이트: ${meal.lunchDate}');
    } else {
      print('➕ 새로운 급식 데이터 추가: ${meal.lunchDate}');
    }
    await _mealBox?.put(meal.lunchDate, meal);
  }

  // 여러 급식 데이터 upsert
  Future<void> upsertMeals(List<DailyMeal> meals) async {
    print('🔄 ${meals.length}개의 급식 데이터 upsert 시작...');

    for (final meal in meals) {
      await upsertMeal(meal);
    }

    print('✅ 급식 데이터 upsert 완료');
  }

  // 급식 데이터 마지막 갱신일 가져오기 (기본값: 1970-01-01)
  String getLastMealUpdatedAt() {
    return _userBox?.get('last_meal_updated_at', defaultValue: '1970-01-01') ??
        '1970-01-01';
  }

  // 급식 데이터 마지막 갱신일 설정
  Future<void> setLastMealUpdatedAt(String updatedAt) async {
    await _userBox?.put('last_meal_updated_at', updatedAt);
    print('📅 급식 마지막 갱신일 업데이트: $updatedAt');
  }

  // 모든 급식 데이터 삭제
  Future<void> clearAllMeals() async {
    print('🗑️ 모든 급식 데이터 삭제 시작...');
    await _mealBox?.clear();
    print('✅ 모든 급식 데이터 삭제 완료');
  }

  // 닉네임 관련 메서드들

  // 닉네임 저장
  Future<void> saveNickname(String nickname) async {
    await _userBox?.put('nickname', nickname);
    print('✅ 닉네임 저장 완료: $nickname');
  }

  // 닉네임 가져오기
  String getNickname() {
    return _userBox?.get('nickname', defaultValue: '') ?? '';
  }

  // 기본 재료들 (쌀, 소금, 설탕, 참기름) 자동 획득
  Future<List<Map<String, dynamic>>> grantBasicIngredients() async {
    print('🎁 기본 재료 자동 획득 시작...');

    // 기본 재료들의 이름으로 ID 찾기
    final allFoods = getAllFoods();
    final basicIngredientNames = ['쌀', '밀', '깨', '소금', '설탕'];
    final now = DateTime.now();
    final List<Map<String, dynamic>> grantedIngredients = [];

    for (final name in basicIngredientNames) {
      try {
        final food = allFoods.firstWhere((f) => f.name == name);

        if (food.acquiredAt == null) {
          // Hive에 획득 상태 업데이트
          await updateFoodAcquiredAt(food.id, now);
          print('✅ 기본 재료 획득: $name (ID: ${food.id})');

          // 반환할 리스트에 추가
          grantedIngredients.add({
            'id': food.id,
            'acquired_at': now.toIso8601String(),
          });
        } else {
          print('ℹ️ 이미 획득한 기본 재료: $name');
        }
      } catch (e) {
        print('⚠️ 기본 재료를 찾을 수 없음: $name');
      }
    }

    print('🎁 기본 재료 자동 획득 완료: ${grantedIngredients.length}개');
    return grantedIngredients;
  }

  // ===== 캐시/데이터 지우기 기능 =====

  /// 이미지 캐시 지우기 (앱 문서 디렉토리의 이미지 파일들)
  Future<void> clearImageCache() async {
    try {
      print('🗑️ 이미지 캐시 지우기 시작...');

      // Flutter의 getApplicationDocumentsDirectory에서 이미지 파일들 삭제
      // (downloadImage에서 저장한 파일들)
      final directory = await _getApplicationDocumentsDirectory();
      if (directory.existsSync()) {
        final files = directory.listSync();
        int deletedCount = 0;

        for (final file in files) {
          if (file is File) {
            final fileName = file.path.split('/').last;
            // 이미지 파일 확장자 확인
            if (fileName.endsWith('.jpg') ||
                fileName.endsWith('.jpeg') ||
                fileName.endsWith('.png') ||
                fileName.endsWith('.webp')) {
              try {
                await file.delete();
                deletedCount++;
                print('🗑️ 이미지 파일 삭제: $fileName');
              } catch (e) {
                print('⚠️ 파일 삭제 실패: $fileName - $e');
              }
            }
          }
        }

        print('✅ 이미지 캐시 삭제 완료: ${deletedCount}개 파일');
      } else {
        print('ℹ️ 앱 문서 디렉토리가 존재하지 않습니다.');
      }
    } catch (e) {
      print('❌ 이미지 캐시 삭제 실패: $e');
    }
  }

  /// 사용자 획득 데이터만 지우기 (음식 기본 정보는 유지)
  Future<void> clearUserAcquiredData() async {
    try {
      print('🗑️ 사용자 획득 데이터 지우기 시작...');

      // 모든 음식의 acquiredAt을 null로 변경
      final allFoods = getAllFoods();
      int clearedCount = 0;

      for (final food in allFoods) {
        if (food.acquiredAt != null) {
          final clearedFood = food.copyWith(acquiredAt: null);
          await _foodBox?.put(food.id, clearedFood);
          clearedCount++;
        }
      }

      // 급식 획득 상태 초기화
      final allMeals = getAllMeals();
      for (final meal in allMeals) {
        if (meal.isAcquired) {
          final clearedMeal = meal.copyWith(isAcquired: false);
          await _mealBox?.put(meal.lunchDate, clearedMeal);
        }
      }

      print('✅ 사용자 획득 데이터 삭제 완료: ${clearedCount}개 음식');
    } catch (e) {
      print('❌ 사용자 획득 데이터 삭제 실패: $e');
    }
  }

  /// 사용자 정보 지우기 (닉네임, UUID 등)
  Future<void> clearUserInfo() async {
    try {
      print('🗑️ 사용자 정보 지우기 시작...');

      // 닉네임 삭제
      await _userBox?.delete('nickname');

      // UUID 및 사용자 정보 삭제
      await _metadataBox?.delete('uuid');
      await _metadataBox?.delete('user_info');

      print('✅ 사용자 정보 삭제 완료');
    } catch (e) {
      print('❌ 사용자 정보 삭제 실패: $e');
    }
  }

  /// 동기화 메타데이터 지우기 (last_updated_at 등)
  Future<void> clearSyncMetadata() async {
    try {
      print('🗑️ 동기화 메타데이터 지우기 시작...');

      // last_updated_at 관련 키들 삭제
      final keys = _metadataBox?.keys.toList() ?? [];
      int deletedCount = 0;

      for (final key in keys) {
        if (key.toString().startsWith('last_updated_')) {
          await _metadataBox?.delete(key);
          deletedCount++;
        }
      }

      print('✅ 동기화 메타데이터 삭제 완료: ${deletedCount}개 항목');
    } catch (e) {
      print('❌ 동기화 메타데이터 삭제 실패: $e');
    }
  }

  /// 전체 앱 데이터 지우기 (기본 음식/급식 데이터는 유지, 사용자 데이터만 삭제)
  Future<void> clearAllUserData() async {
    try {
      print('🗑️ 전체 사용자 데이터 지우기 시작...');

      // 사용자 획득 데이터 삭제
      await clearUserAcquiredData();

      // 사용자 정보 삭제
      await clearUserInfo();

      // 동기화 메타데이터 삭제
      await clearSyncMetadata();

      // 이미지 캐시 삭제
      await clearImageCache();

      print('✅ 전체 사용자 데이터 삭제 완료');
    } catch (e) {
      print('❌ 전체 사용자 데이터 삭제 실패: $e');
    }
  }

  /// 앱 완전 초기화 (모든 Hive 박스 데이터 삭제)
  Future<void> clearAllAppData() async {
    try {
      print('🗑️ 앱 완전 초기화 시작...');

      // 모든 박스 클리어
      await _foodBox?.clear();
      await _mealBox?.clear();
      await _metadataBox?.clear();
      await _userBox?.clear();

      // SharedPreferences도 완전 삭제 (개발자 모드 상태 포함)
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      print('🗑️ SharedPreferences 전체 삭제 완료');

      // 이미지 캐시 삭제
      await clearImageCache();

      print('✅ 앱 완전 초기화 완료 (Hive + SharedPreferences + 이미지 캐시)');
    } catch (e) {
      print('❌ 앱 완전 초기화 실패: $e');
    }
  }

  // 헬퍼 메서드: 앱 문서 디렉토리 가져오기
  Future<Directory> _getApplicationDocumentsDirectory() async {
    try {
      // path_provider를 사용하여 실제 앱 문서 디렉토리 가져오기
      return await getApplicationDocumentsDirectory();
    } catch (e) {
      print('⚠️ 앱 문서 디렉토리 가져오기 실패: $e');
      // 폴백으로 임시 디렉토리 사용
      return await getTemporaryDirectory();
    }
  }
}
