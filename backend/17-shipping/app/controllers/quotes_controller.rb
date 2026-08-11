class QuotesController < ApplicationController
  before_action :require_user!

  # GET /api/v1/shipping/quote?tier=&weight=&upazila=  — the REST twin of the gRPC.
  def show
    tier = params[:tier]
    return render_error("invalid_request", "tier is required", status: 422) if tier.blank?
    q = CourierSelector.quote(address_tier: tier, weight_grams: params[:weight].to_i, upazila_code: params[:upazila])
    return render_error("no_courier", "no active courier serves this tier", status: 422) unless q
    ShippingMetrics.quote!(q[:courier])
    render_pretty({ courier: q[:courier], fee_minor: q[:fee_minor], eta_hours: q[:eta_hours],
                    distance_km: q[:distance_km], source: q[:distance_source] })
  end
end
