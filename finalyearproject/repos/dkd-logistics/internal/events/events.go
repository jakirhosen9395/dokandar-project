// Package events builds the six logistics.shipment.* Published-Language payloads
// (frozen registry, producer 9, key SHP; DM payload fields exactly — IDs only, no PII).
package events

import (
	"encoding/json"
	"fmt"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/logistics-svc/internal/logistics"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/store"
)

func build(topic, shp string, fields map[string]any, now int64) store.OutboxRow {
	meta, ok := dkd.TopicMetaFor(topic)
	if !ok || meta.Producer != 9 {
		panic(fmt.Sprintf("R6 violation: logistics may not produce %s", topic))
	}
	eventID := logistics.UUID7()
	payload := map[string]any{"eventId": eventID, "occurredAt": now}
	for k, v := range fields {
		payload[k] = v
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		panic(fmt.Sprintf("events: marshal %s: %v", topic, err))
	}
	return store.OutboxRow{EventID: eventID, Topic: topic, Key: shp, Payload: raw}
}

func ShipmentCreated(shp, refID, refType string, now int64) store.OutboxRow {
	return build(dkd.TopicLogisticsShipmentShipmentCreatedV1, shp,
		map[string]any{"shp": shp, "shipmentId": shp, "referenceId": refID, "referenceType": refType, "createdAt": now}, now)
}

func RiderAssigned(shp, riderDid string, now int64) store.OutboxRow {
	return build(dkd.TopicLogisticsShipmentRiderAssignedV1, shp,
		map[string]any{"shp": shp, "riderDid": riderDid, "assignedAt": now}, now)
}

func PickupRecorded(shp string, now int64) store.OutboxRow {
	return build(dkd.TopicLogisticsShipmentPickupRecordedV1, shp,
		map[string]any{"shp": shp, "pickedUpAt": now}, now)
}

func DeliveryRecorded(shp, refID, refType string, deliveredAt, now int64) store.OutboxRow {
	return build(dkd.TopicLogisticsShipmentDeliveryRecordedV1, shp,
		map[string]any{"shp": shp, "referenceId": refID, "referenceType": refType,
			"orderId": refID, "deliveredAt": deliveredAt}, now)
}

func ShipmentCancelled(shp, refID, refType, reason string, now int64) store.OutboxRow {
	return build(dkd.TopicLogisticsShipmentShipmentCancelledV1, shp,
		map[string]any{"shp": shp, "referenceId": refID, "referenceType": refType,
			"reason": reason, "cancelledAt": now}, now)
}

func DeliveryFailed(shp, refID, refType, reason string, now int64) store.OutboxRow {
	return build(dkd.TopicLogisticsShipmentDeliveryFailedV1, shp,
		map[string]any{"shp": shp, "referenceId": refID, "referenceType": refType,
			"reason": reason, "failedAt": now}, now)
}
