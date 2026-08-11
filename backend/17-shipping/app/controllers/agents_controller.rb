class AgentsController < ApplicationController
  before_action :require_user!, only: [:index]
  before_action :require_admin!, only: [:create]

  # GET /api/v1/shipping/admin/agents[?upazila=]
  def index
    agents = RuralAgent.where(active: true)
    agents = agents.where(upazila_code: params[:upazila]) if params[:upazila].present?
    render_pretty({ agents: agents.map { |a| { id: a.id, upazila_code: a.upazila_code, name: a.name, active: a.active } } })
  end

  # POST /api/v1/shipping/admin/agents  (admin)
  def create
    return render_error("invalid_request", "upazila_code and name are required", status: 422) if params[:upazila_code].blank? || params[:name].blank?
    a = RuralAgent.create!(upazila_code: params[:upazila_code], name: params[:name], phone: params[:phone], active: true)
    render_pretty({ id: a.id, upazila_code: a.upazila_code, name: a.name }, status: 201)
  end
end
