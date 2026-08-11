class ShipmentsController < ApplicationController
  before_action :require_user!

  # POST /api/v1/shipping/shipments  (Idempotency-Key required) — 201 | 401 | 409 | 422
  def create
    idem = request.headers["Idempotency-Key"]
    return render_error("missing_idempotency_key", "Idempotency-Key header required", status: 400) if idem.to_s.empty?
    sub = params[:sub_order_id]
    tier = params[:address_tier]
    return render_error("invalid_request", "sub_order_id and address_tier are required", status: 422) if sub.blank? || tier.blank?

    res = ShippingBooking.book(sub_order_id: sub, address_tier: tier, upazila_code: params[:upazila_code],
                               cod_amount_minor: params[:cod_amount_minor], idempotency_key: idem)
    if res.created
      render_pretty(res.shipment.to_dto, status: 201)
    else
      render_error("already_booked", "a shipment already exists for this idempotency key", status: 409)
    end
  end

  # GET /api/v1/shipping/shipments/:id
  def show
    s = Shipment.find_by(id: params[:id])
    return render_error("not_found", "shipment not found", status: 404) unless s
    render_pretty(s.to_dto)
  end

  # GET /api/v1/shipping/shipments/by-order/:sub_order_id
  def by_order
    s = Shipment.where(sub_order_id: params[:sub_order_id]).order(created_at: :desc).first
    return render_error("not_found", "no shipment for that sub-order", status: 404) unless s
    render_pretty(s.to_dto)
  end
end
