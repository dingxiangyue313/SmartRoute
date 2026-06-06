from core.agents.intent_parser import IntentParserAgent
from core.agents.poi_retriever import POIRetrieverAgent
from core.agents.route_planner import RoutePlannerAgent
from core.models import POI, POICategory
from core.rag.vector_store import POIVectorStore
from data.seed_db import generate_mock_pois


def test_pipeline_generates_route(tmp_path):
    pois_raw = generate_mock_pois(80)
    poi_db = {item["id"]: POI(**item) for item in pois_raw}
    store = POIVectorStore(str(tmp_path / "index"))
    store.index_pois(pois_raw)

    intent = IntentParserAgent().parse("帮我规划一个上海外滩附近的文艺下午，时间3小时，两个人，预算200，不想排队")
    candidates = POIRetrieverAgent(store, poi_db).retrieve(intent)
    routes = RoutePlannerAgent(poi_db).plan(intent, candidates, n_routes=2)

    assert candidates
    assert routes
    assert routes[0].stops
    assert len(routes[0].stops) >= 3
    categories = {stop.poi.category for stop in routes[0].stops}
    assert categories.intersection({POICategory.RESTAURANT, POICategory.CAFE})
    assert categories.intersection({POICategory.ATTRACTION, POICategory.ENTERTAINMENT})
    assert routes[0].total_time_minutes <= 3 * 60 + 45


def make_test_poi(name, category, index, price=60, wait=8, rating=4.6):
    return POI(
        id=f"test-{index}",
        name=name,
        category=category,
        address="深圳福田",
        district="深圳",
        latitude=22.54 + index * 0.002,
        longitude=114.05 + index * 0.002,
        rating=rating,
        review_count=500,
        price_per_person=price,
        avg_wait_minutes=wait,
        business_hours={"open": "09:00", "close": "22:00"},
        tags=[category.value],
        ugc_summary=f"{name} 适合路线规划",
        visit_duration_minutes=45,
        source="amap",
    )


def test_route_planner_avoids_consecutive_cafes_by_default():
    pois = [
        make_test_poi("星巴克", POICategory.CAFE, 1, rating=4.8),
        make_test_poi("NEST PANCAKE CAFE", POICategory.CAFE, 2, rating=4.7),
        make_test_poi("抱抱小狗咖啡", POICategory.CAFE, 3, rating=4.6),
        make_test_poi("福田红树林生态公园科普展馆", POICategory.ATTRACTION, 4, price=20),
        make_test_poi("深业上城生活中心", POICategory.SHOPPING, 5, price=30),
        make_test_poi("福田轻食餐厅", POICategory.RESTAURANT, 6, price=90),
    ]
    intent = IntentParserAgent().parse("福田文艺下午3小时")
    candidates = [(poi, 5.0 - index * 0.1) for index, poi in enumerate(pois)]
    routes = RoutePlannerAgent({poi.id: poi for poi in pois}).plan(intent, candidates, n_routes=1)

    assert routes
    stops = routes[0].stops
    categories = [stop.poi.category for stop in stops]
    assert categories.count(POICategory.CAFE) <= 1
    assert not any(categories[index] == categories[index - 1] for index in range(1, len(categories)))
    assert any(category in {POICategory.ATTRACTION, POICategory.ENTERTAINMENT, POICategory.SHOPPING} for category in categories)


def test_route_planner_allows_explicit_coffee_hopping():
    pois = [
        make_test_poi("精品咖啡一号", POICategory.CAFE, 1, rating=4.8),
        make_test_poi("精品咖啡二号", POICategory.CAFE, 2, rating=4.7),
        make_test_poi("精品咖啡三号", POICategory.CAFE, 3, rating=4.6),
        make_test_poi("城市展馆", POICategory.ATTRACTION, 4, price=20),
    ]
    intent = IntentParserAgent().parse("福田咖啡店巡游3小时")
    candidates = [(poi, 5.0 - index * 0.1) for index, poi in enumerate(pois)]
    routes = RoutePlannerAgent({poi.id: poi for poi in pois}).plan(intent, candidates, n_routes=1)

    assert routes
    categories = [stop.poi.category for stop in routes[0].stops]
    assert categories.count(POICategory.CAFE) >= 2
